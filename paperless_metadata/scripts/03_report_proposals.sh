#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
PROPOSALS_DIR="$PROJECT_DIR/state/proposals"

exec python3 - "$PROPOSALS_DIR" <<'PY'
import json
import sys
from pathlib import Path
from collections import Counter

directory = Path(sys.argv[1])
files = sorted(directory.glob("*.json"))
docs = []
invalid = []

for path in files:
    try:
        with path.open("r", encoding="utf-8") as f:
            item = json.load(f)
        if not isinstance(item, dict) or item.get("document_id") is None:
            raise ValueError("document_id fehlt")
        docs.append(item)
    except Exception as exc:
        invalid.append((path.name, str(exc)))

def proposal(d):
    return d.get("proposal") or {}

def warnings(d):
    value = proposal(d).get("validation_warnings") or []
    return len(value) if isinstance(value, list) else 1

def confidence(d):
    try:
        value = proposal(d).get("confidence")
        return float(value) if value is not None else None
    except (ValueError, TypeError):
        return None

def title(d):
    return str((d.get("existing") or {}).get("title") or "-")

print("=" * 68)
print("PAPERLESS – AUSWERTUNG DER METADATEN-VORSCHLÄGE")
print("=" * 68)
print(f"JSON-Dateien: {len(files)} | Gültig: {len(docs)} | Fehlerhaft: {len(invalid)}")
print()

if not docs:
    print("Keine gültigen Vorschläge vorhanden.")
    sys.exit(0)

print("--- GESAMTÜBERSICHT ---")
print(f"Manuelle Prüfung erforderlich: {sum(proposal(d).get('requires_review') is True for d in docs)}")
print(f"Mit Warnungen:                {sum(warnings(d) > 0 for d in docs)}")
print(f"Konfidenz unter 70 %:         {sum(confidence(d) is not None and confidence(d) < 0.7 for d in docs)}")
print(f"Konfidenz fehlt:              {sum(confidence(d) is None for d in docs)}")
print(f"Bereits angewendet:           {sum(d.get('applied') is True for d in docs)}")
print(f"Noch nicht angewendet:        {sum(d.get('applied') is not True for d in docs)}")
print(f"Korrespondent vorgeschlagen:  {sum(bool(proposal(d).get('correspondent_suggestion')) for d in docs)}")
print(f"Zusätzliche Tags:             {sum(bool(proposal(d).get('additional_tags')) for d in docs)}")

print("\n--- HAUPTKATEGORIEN ---")
categories = Counter(proposal(d).get("primary_tag") or "(keine Kategorie)" for d in docs)
for category, count in categories.most_common():
    print(f"{count:4}  {category}")

print("\n--- AUFFÄLLIGE DOKUMENTE ---")
flagged = [
    d for d in docs
    if proposal(d).get("requires_review") is True
    or warnings(d) > 0
    or confidence(d) is None
    or confidence(d) < 0.7
]
if not flagged:
    print("Keine Auffälligkeiten nach den definierten Kriterien.")
else:
    for d in flagged:
        p = proposal(d)
        c = confidence(d)
        confidence_text = f"{c:.0%}" if c is not None else "fehlt"
        print(f"ID {d['document_id']} | {title(d)}")
        print(f"  Kategorie: {p.get('primary_tag') or '-'} | Konfidenz: {confidence_text}")
        print(f"  Prüfung: {'JA' if p.get('requires_review') is True else 'nein'}")
        if warnings(d):
            print(f"  Warnungen: {json.dumps(p.get('validation_warnings'), ensure_ascii=False)}")

if invalid:
    print("\n--- FEHLERHAFTE DATEIEN ---")
    for name, error in invalid:
        print(f"{name}: {error}")

print("\nAuswertung abgeschlossen. Es wurden keine Dateien verändert.")
PY
