#!/usr/bin/env python3
import csv
import json
import re
import unicodedata
from collections import defaultdict
from difflib import SequenceMatcher
from pathlib import Path

BASE = Path("/home/pi/docker/paperless/paperless_metadata")
SOURCE = BASE / "state/proposals"
REPORTS = BASE / "state/reports"

def normalize(value):
    value = unicodedata.normalize("NFKD", value.casefold())
    value = "".join(c for c in value if not unicodedata.combining(c))
    value = re.sub(r"[^a-z0-9]+", " ", value)
    return " ".join(value.split())

# Rechtsformzusätze werden für den Ähnlichkeitsvergleich entfernt,
# aber niemals automatisch aus dem tatsächlichen Namen gelöscht.
LEGAL_SUFFIXES = (
    " gesellschaft mit beschrankter haftung",
    " gemeinnutzige gesellschaft mit beschrankter haftung",
    " aktiengesellschaft",
    " gesellschaft burgerlichen rechts",
    " eingetragener verein",
    " limited",
    " gmbh co kg",
    " gmbh",
    " ag",
    " kg",
    " e v",
    " ev",
    " ltd",
    " inc",
)

def comparison_key(value):
    key = normalize(value)
    changed = True
    while changed:
        changed = False
        for suffix in LEGAL_SUFFIXES:
            if key.endswith(suffix):
                key = key[:-len(suffix)].strip()
                changed = True
                break
    return key or normalize(value)

REPORTS.mkdir(parents=True, exist_ok=True)
documents_by_name = defaultdict(list)

for path in sorted(SOURCE.glob("*.json")):
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"WARNUNG: {path.name}: {exc}")
        continue

    proposal = data.get("proposal") or {}
    name = proposal.get("correspondent_suggestion")
    if not isinstance(name, str) or not name.strip():
        continue

    name = " ".join(name.split())
    document_id = data.get("document_id", data.get("id", path.stem))
    documents_by_name[name].append(str(document_id))

names = sorted(documents_by_name, key=str.casefold)

name_file = REPORTS / "korrespondenten_namensliste.csv"
with name_file.open("w", newline="", encoding="utf-8-sig") as f:
    writer = csv.writer(f, delimiter=";")
    writer.writerow(["Korrespondent", "Anzahl_Dokumente", "Dokument_IDs"])
    for name in names:
        ids = sorted(set(documents_by_name[name]), key=lambda x: (not x.isdigit(), x))
        writer.writerow([name, len(ids), ", ".join(ids)])

# Exakt identische normalisierte Namen sowie ähnliche Namen aufführen.
# Dies sind ausschließlich Prüfkandidaten, keine bestätigten Dubletten.
candidates = []
keys = {name: comparison_key(name) for name in names}

for i, first in enumerate(names):
    for second in names[i + 1:]:
        a, b = keys[first], keys[second]
        if not a or not b:
            continue

        score = SequenceMatcher(None, a, b).ratio()
        if a == b:
            score = 1.0

        if score >= 0.72:
            candidates.append((
                score, first, second,
                len(documents_by_name[first]),
                len(documents_by_name[second]),
            ))

candidates.sort(key=lambda row: (-row[0], row[1].casefold(), row[2].casefold()))

candidate_file = REPORTS / "korrespondenten_kandidaten.csv"
with candidate_file.open("w", newline="", encoding="utf-8-sig") as f:
    writer = csv.writer(f, delimiter=";")
    writer.writerow([
        "Aehnlichkeit_Prozent", "Name_1", "Dokumente_1",
        "Name_2", "Dokumente_2", "Entscheidung", "Einheitlicher_Name"
    ])
    for score, first, second, count1, count2 in candidates:
        writer.writerow([
            round(score * 100, 1), first, count1, second, count2, "", ""
        ])

print(f"Dokumente mit Korrespondentenvorschlag: "
      f"{sum(map(len, documents_by_name.values()))}")
print(f"Unterschiedliche Namen: {len(names)}")
print(f"Mögliche Dublettenpaare zur Prüfung: {len(candidates)}")
print(f"\nNamensliste: {name_file}")
print(f"Prüfliste:   {candidate_file}")
print("\nEs wurden keine Paperless-Daten verändert.")
