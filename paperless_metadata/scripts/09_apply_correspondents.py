#!/usr/bin/env python3
import csv
import json
import os
import sys
from datetime import datetime
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urljoin
from urllib.request import Request, urlopen

BASE = Path("/home/pi/docker/paperless/paperless_metadata")
SOURCE = BASE / "state/correspondent_proposals"
REPORT_DIR = BASE / "state/reports"
API_URL = os.environ.get("PAPERLESS_URL", "http://rasp2:1888").rstrip("/") + "/api/"
TOKEN = os.environ.get("PAPERLESS_TOKEN", "").strip()

if "--apply" not in sys.argv:
    sys.exit("Abbruch: Für echte Änderungen bitte ausdrücklich --apply angeben.")
if not TOKEN:
    sys.exit("PAPERLESS_TOKEN ist nicht gesetzt.")
if not SOURCE.is_dir():
    sys.exit(f"Vorschlagsverzeichnis fehlt: {SOURCE}")

REPORT_DIR.mkdir(parents=True, exist_ok=True)
stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
report_path = REPORT_DIR / f"korrespondenten_uebernahme_{stamp}.json"

def api(method, endpoint, payload=None):
    url = endpoint if endpoint.startswith("http") else urljoin(API_URL, endpoint)
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    headers = {
        "Authorization": f"Token {TOKEN}",
        "Accept": "application/json",
    }
    if data is not None:
        headers["Content-Type"] = "application/json"
    req = Request(url, data=data, headers=headers, method=method)
    try:
        with urlopen(req, timeout=60) as response:
            raw = response.read()
            return json.loads(raw) if raw else {}
    except HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {exc.code} bei {method} {url}: {detail}") from exc
    except (URLError, TimeoutError) as exc:
        raise RuntimeError(f"API-Verbindungsfehler bei {method} {url}: {exc}") from exc

def get_all(endpoint):
    result = []
    url = urljoin(API_URL, endpoint)
    while url:
        page = api("GET", url)
        if isinstance(page, dict) and "results" in page:
            result.extend(page["results"])
            url = page.get("next")
        elif isinstance(page, list):
            result.extend(page)
            url = None
        else:
            raise RuntimeError(f"Unerwartete API-Antwort für {endpoint}")
    return result

# Vorschläge einlesen und prüfen
proposals = []
for path in sorted(SOURCE.glob("*.json")):
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        doc_id = data.get("document_id", data.get("id"))
        name = (data.get("proposal") or {}).get("correspondent")
        if doc_id is None or not isinstance(name, str) or not name.strip():
            print(f"WARNUNG: Ungültiger Vorschlag: {path.name}")
            continue
        proposals.append({
            "document_id": int(doc_id),
            "name": name.strip(),
            "source_file": path.name,
            "title": (data.get("existing") or {}).get("title", ""),
        })
    except (OSError, ValueError, TypeError, json.JSONDecodeError) as exc:
        print(f"WARNUNG: {path.name}: {exc}")

if not proposals:
    sys.exit("Keine gültigen Korrespondentenvorschläge gefunden.")

# Mehrfachdateien für dieselbe Dokument-ID verhindern
by_id = {}
for item in proposals:
    if item["document_id"] in by_id:
        old = by_id[item["document_id"]]
        if old["name"] != item["name"]:
            sys.exit(
                f"Abbruch: Dokument {item['document_id']} hat widersprüchliche "
                f"Vorschläge: {old['name']!r} / {item['name']!r}"
            )
    else:
        by_id[item["document_id"]] = item
proposals = list(by_id.values())

print(f"Vorschläge geladen: {len(proposals)} Dokumente")
print("Prüfe Paperless-API und vorhandene Korrespondenten ...")

# API-Zugang vor jeglicher Änderung prüfen
api("GET", "documents/?page_size=1")
correspondents = get_all("correspondents/")
name_to_id = {
    c["name"].strip(): c["id"]
    for c in correspondents
    if isinstance(c.get("name"), str)
}
print(f"Vorhandene Korrespondenten: {len(name_to_id)}")

# Fehlende Korrespondenten anlegen
names = sorted({p["name"] for p in proposals}, key=str.casefold)
created = 0
create_errors = {}

for name in names:
    if name in name_to_id:
        continue
    try:
        item = api("POST", "correspondents/", {"name": name})
        name_to_id[item["name"].strip()] = item["id"]
        created += 1
        print(f"ANGELEGT: {name}")
    except Exception as exc:
        # Bei möglichem Konflikt erneut einlesen, bevor ein Fehler gemeldet wird.
        try:
            refreshed = get_all("correspondents/")
            name_to_id.update({
                c["name"].strip(): c["id"]
                for c in refreshed if isinstance(c.get("name"), str)
            })
        except Exception:
            pass
        if name not in name_to_id:
            create_errors[name] = str(exc)
            print(f"FEHLER beim Anlegen von {name}: {exc}")

# Dokumente zuordnen und jeden Versuch protokollieren
results = []
for index, item in enumerate(proposals, 1):
    doc_id = item["document_id"]
    name = item["name"]
    row = {
        **item,
        "correspondent_id": name_to_id.get(name),
        "status": "",
        "error": None,
    }

    if name not in name_to_id:
        row["status"] = "CORRESPONDENT_CREATE_FAILED"
        row["error"] = create_errors.get(name, "Korrespondent nicht vorhanden")
        results.append(row)
        continue

    try:
        doc = api("GET", f"documents/{doc_id}/")
        current = doc.get("correspondent")

        if current == name_to_id[name]:
            row["status"] = "ALREADY_CORRECT"
        elif current is not None:
            row["status"] = "SKIPPED_EXISTING_ASSIGNMENT"
            row["current_correspondent_id"] = current
        else:
            api("PATCH", f"documents/{doc_id}/", {
                "correspondent": name_to_id[name]
            })
            # Rücklesen: Nur eine bestätigte Zuordnung zählt als Erfolg.
            updated = api("GET", f"documents/{doc_id}/")
            if updated.get("correspondent") == name_to_id[name]:
                row["status"] = "ASSIGNED"
            else:
                row["status"] = "VERIFY_FAILED"
                row["error"] = (
                    f"Erwartet ID {name_to_id[name]}, "
                    f"erhalten {updated.get('correspondent')}"
                )
    except Exception as exc:
        row["status"] = "ERROR"
        row["error"] = str(exc)

    results.append(row)
    if index % 25 == 0 or index == len(proposals):
        print(f"Fortschritt: {index}/{len(proposals)}")

counts = {}
for row in results:
    counts[row["status"]] = counts.get(row["status"], 0) + 1

report = {
    "timestamp": datetime.now().astimezone().isoformat(),
    "api_url": API_URL,
    "proposal_count": len(proposals),
    "unique_suggested_names": len(names),
    "correspondents_before": len(correspondents),
    "correspondents_created": created,
    "correspondents_create_errors": create_errors,
    "document_results": counts,
    "results": results,
}
report_path.write_text(
    json.dumps(report, ensure_ascii=False, indent=2),
    encoding="utf-8"
)

csv_path = report_path.with_suffix(".csv")
with csv_path.open("w", newline="", encoding="utf-8-sig") as f:
    writer = csv.DictWriter(
        f,
        fieldnames=[
            "document_id", "title", "name", "correspondent_id",
            "status", "current_correspondent_id", "error", "source_file"
        ],
        delimiter=";"
    )
    writer.writeheader()
    for row in results:
        writer.writerow({key: row.get(key, "") for key in writer.fieldnames})

print("\n========== ERGEBNIS ==========")
print(f"Vorschläge verarbeitet:             {len(proposals)}")
print(f"Neue Korrespondenten angelegt:      {created}")
print(f"Erfolgreich neu zugeordnet:         {counts.get('ASSIGNED', 0)}")
print(f"Bereits korrekt zugeordnet:         {counts.get('ALREADY_CORRECT', 0)}")
print(f"Bestehende Zuordnung übersprungen:  {counts.get('SKIPPED_EXISTING_ASSIGNMENT', 0)}")
print(f"Anlegefehler:                       {len(create_errors)}")
print(f"Sonstige Fehler:                    {counts.get('ERROR', 0) + counts.get('VERIFY_FAILED', 0)}")
print(f"\nJSON-Bericht: {report_path}")
print(f"CSV-Bericht:  {csv_path}")
