#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError

BASE = Path("/home/pi/docker/paperless/paperless_metadata")
REPORT = BASE / "state/reports/korrespondenten_uebernahme_20261010_141018.json"
OUT = BASE / "state/reports/korrespondenten_kontrolle.json"

token = os.environ.get("PAPERLESS_TOKEN", "").strip()
api_base = os.environ.get(
"PAPERLESS_URL", "http://rasp2:1888"
).rstrip("/") + "/api/"

if not token:
sys.exit("FEHLER: PAPERLESS_TOKEN ist nicht gesetzt.")
if not REPORT.is_file():
sys.exit(f"FEHLER: Bericht nicht gefunden: {REPORT}")

with REPORT.open(encoding="utf-8") as f:
report = json.load(f)

results = []
for item in report["results"]:
if item["status"] not in ("ASSIGNED", "ALREADY_CORRECT"):
continue

doc_id = item["document_id"]
expected_id = item.get("correspondent_id")
url = f"{api_base}documents/{doc_id}/"
req = Request(url, headers={
    "Authorization": f"Token {token}",
    "Accept": "application/json",
})

row = {
    "document_id": doc_id,
    "title": item.get("title", ""),
    "expected_correspondent": item["name"],
    "expected_id": expected_id,
}

try:
    with urlopen(req, timeout=30) as response:
        doc = json.loads(response.read())
    actual_id = doc.get("correspondent")
    row["actual_correspondent_id"] = actual_id

    if actual_id == expected_id:
        row["status"] = "OK"
    elif actual_id is None:
        row["status"] = "MISSING"
    else:
        row["status"] = "MISMATCH"
except (HTTPError, URLError, TimeoutError, json.JSONDecodeError) as exc:
    row["status"] = "ERROR"
    row["error"] = str(exc)

results.append(row)

counts = {}
for row in results:
counts[row["status"]] = counts.get(row["status"], 0) + 1

output = {
"documents_checked": len(results),
"status_counts": counts,
"results": results,
}
OUT.write_text(json.dumps(output, ensure_ascii=False, indent=2), encoding="utf-8")

print("=== Kontrolle der Korrespondentenzuordnungen ===")
print(f"Geprüfte Dokumente:       {len(results)}")
print(f"Korrekt gespeichert:      {counts.get('OK', 0)}")
print(f"Korrespondent fehlt:      {counts.get('MISSING', 0)}")
print(f"Abweichende Zuordnung:    {counts.get('MISMATCH', 0)}")
print(f"API-/Lesefehler:          {counts.get('ERROR', 0)}")
print(f"Kontrollbericht: {OUT}")

problems = [r for r in results if r["status"] != "OK"]
if problems:
print("\n=== Prüffälle ===")
for row in problems:
print(
f"ID {row['document_id']} | {row['status']} | "
f"{row.get('title', '')} | {row.get('error', '')}"
)
