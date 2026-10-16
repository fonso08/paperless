#!/usr/bin/env bash
set -euo pipefail

cd /home/pi/docker/paperless/paperless_metadata

OUT="state/reports/dateinamen_pruefbericht_$(date +%Y%m%d_%H%M%S).csv"
mkdir -p state/reports

python3 - "$OUT" <<'PY'
import csv
import json
import re
import sys
import unicodedata
from pathlib import Path
from collections import Counter

out = Path(sys.argv[1])
root = Path("state/proposals")

def safe(value):
    value = str(value or "").strip()
    value = value.replace("&", " und ")

    # Deutsche Umlaute und ß vereinheitlichen
    value = (value
             .replace("ä", "ae").replace("Ä", "Ae")
             .replace("ö", "oe").replace("Ö", "Oe")
             .replace("ü", "ue").replace("Ü", "Ue")
             .replace("ß", "ss"))

    value = unicodedata.normalize("NFKD", value)
    value = "".join(c for c in value if not unicodedata.combining(c))
    value = re.sub(r'[<>:"/\|?*\x00-\x1f]', "-", value)
    value = re.sub(r"[^A-Za-z0-9._ -]", "-", value)
    value = re.sub(r"[\s-]+", "-", value)
    value = re.sub(r"-+", "-", value)
    return value.strip(" .-_")


def fit_filename(base, suffix=""):
    # Maximal 80 Zeichen inklusive .pdf und Konflikt-ID.
    limit = 80 - len(".pdf") - len(suffix)
    if len(base) > limit:
        base = base[:limit].rstrip(" ._-")
        # Möglichst nicht mitten in einem Wort abschneiden.
        if "-" in base:
            base = base.rsplit("-", 1)[0].rstrip(" ._-")
    return base + suffix + ".pdf"

records = []
errors = []

for path in sorted(root.glob("*.json")):
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        existing = data.get("existing") or {}
        proposal = data.get("proposal") or {}

        doc_id = str(data.get("document_id", path.stem))
        current = existing.get("original_file_name") or ""
        title = existing.get("title") or Path(current).stem or f"Dokument-{doc_id}"
        category = proposal.get("primary_tag") or ""
        correspondent = (
            proposal.get("correspondent")
            or proposal.get("correspondent_suggestion")
            or existing.get("correspondent")
            or ""
        )
        date = str(proposal.get("document_date") or existing.get("created") or "")
        match = re.fullmatch(r"(\d{4})-(\d{2})-(\d{2})", date)
        datepart = "".join(match.groups()) if match else ""

        warnings = []
        if not match:
            warnings.append("Datum fehlt/ungueltig")
        if not category:
            warnings.append("Kategorie fehlt")
        if not title:
            warnings.append("Titel fehlt")
        if not correspondent:
            warnings.append("Korrespondent ausgelassen")

        parts = [
            datepart,
            safe(category),
            safe(correspondent),
            safe(title),
        ]
        filename = fit_filename("_".join(part for part in parts if part))

        if not datepart:
            filename = "OHNE-DATUM_" + filename

        records.append({
            "id": doc_id,
            "current": current,
            "date": date,
            "datepart": datepart or "FEHLT",
            "category": category,
            "correspondent": correspondent,
            "title": title,
            "proposed": filename,
            "warnings": warnings,
            "conflict": "",
        })

    except Exception as exc:
        errors.append(f"{path}: {exc}")

# Aktuelle Namen innerhalb der analysierten Dokumente erfassen.
current_names = {}
for r in records:
    if r["current"]:
        current_names.setdefault(r["current"].casefold(), []).append(r["id"])

# Doppelte vorgeschlagene Namen erkennen.
counts = Counter(r["proposed"].casefold() for r in records)

for r in records:
    conflicts = []

    if counts[r["proposed"].casefold()] > 1:
        conflicts.append("Doppelter Vorschlag")

    # Prüfen, ob der Vorschlag den aktuellen Namen eines anderen
    # der analysierten Dokumente belegen würde.
    owners = current_names.get(r["proposed"].casefold(), [])
    if any(owner != r["id"] for owner in owners):
        conflicts.append("Name aktuell bei anderem analysierten Dokument")

    if conflicts:
        r["proposed"] = fit_filename(r["proposed"][:-4], "_" + safe(r["id"]))
        r["conflict"] = "; ".join(conflicts)
        r["warnings"].append("Dokument-ID zur Unterscheidung ergänzt")

# Sicherstellen, dass auch nach Ergänzung keine Vorschläge doppelt sind.
seen = set()
for r in records:
    name = r["proposed"]
    if name.casefold() in seen:
        name = fit_filename(name[:-4], "_ID" + safe(r["id"]))
        r["proposed"] = name
        r["conflict"] = (r["conflict"] + "; " if r["conflict"] else "")
        r["conflict"] += "Zusätzliche ID ergänzt"
    seen.add(r["proposed"].casefold())

columns = [
    ("Dokument-ID", "id"),
    ("Aktueller Dateiname", "current"),
    ("Analysiertes Datum", "date"),
    ("Datum JJJJMMTT", "datepart"),
    ("Kategorie", "category"),
    ("Korrespondent", "correspondent"),
    ("Dokumenttitel", "title"),
    ("Vorgeschlagener Dateiname", "proposed"),
    ("Konfliktprüfung", "conflict"),
    ("Prüfhinweise", "warnings"),
]

with out.open("w", encoding="utf-8-sig", newline="") as f:
    writer = csv.writer(f, delimiter=";")
    writer.writerow([label for label, _ in columns])
    for r in sorted(records, key=lambda x: (
        0, int(x["id"]) if x["id"].isdigit() else 0
    )):
        row = []
        for _, key in columns:
            value = r[key]
            if isinstance(value, list):
                value = "; ".join(value)
            row.append(value)
        writer.writerow(row)

print(f"Report: {out}")
print(f"Analysen verarbeitet: {len(records)}")
print(f"Fehlerhafte JSON-Dateien: {len(errors)}")
print(f"Mit Konflikthinweis: {sum(bool(r['conflict']) for r in records)}")
print(f"Mit Prüfhinweisen: {sum(bool(r['warnings']) for r in records)}")
print("Hinweis: Konfliktprüfung umfasst nur die analysierten JSON-Dateien.")

for error in errors[:10]:
    print("FEHLER:", error)
PY

echo
echo "Syntaxprüfung:"
bash -n scripts/06_dateinamen_vergleich.sh

echo
echo "Erste 6 Zeilen:"
head -6 "$OUT" | column -s ';' -t | cut -c1-280
