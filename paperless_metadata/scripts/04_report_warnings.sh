#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
PROPOSALS_DIR="$PROJECT_DIR/state/proposals"

exec python3 - "$PROPOSALS_DIR" <<'PY'
import json
import sys
from pathlib import Path

directory = Path(sys.argv[1])
files = sorted(directory.glob("*.json"))
flagged = []
invalid = []

for path in files:
    try:
        with path.open("r", encoding="utf-8") as f:
            d = json.load(f)

        if not isinstance(d, dict):
            continue

        p = d.get("proposal") or {}
        warnings = p.get("validation_warnings") or []

        if warnings:
            flagged.append((d, warnings))
    except Exception as exc:
        invalid.append((path.name, str(exc)))

print("=" * 72)
print("PAPERLESS – DETAILBERICHT VALIDierungsWARNUNGEN")
print("=" * 72)
print(f"JSON-Dateien: {len(files)}")
print(f"Dokumente mit Warnungen: {len(flagged)}")
print()

for d, warnings in sorted(flagged, key=lambda item: str(item[0].get("document_id", ""))):
    p = d.get("proposal") or {}
    existing = d.get("existing") or {}
    confidence = p.get("confidence")
    confidence_text = (
        f"{float(confidence):.0%}" if isinstance(confidence, (int, float))
        else "nicht angegeben"
    )

    print("-" * 72)
    print(f"Dokument-ID:       {d.get('document_id', '-')}")
    print(f"Titel:             {existing.get('title') or '-'}")
    print(f"Dateiname:         {existing.get('original_file_name') or '-'}")
    print(f"Hauptkategorie:    {p.get('primary_tag') or '-'}")
    print(f"Konfidenz:         {confidence_text}")
    print(f"Prüfung notwendig: {p.get('requires_review', '-')}")
    print(f"Prüfentscheidung:  {p.get('review_decision') or '-'}")
    print("Warnungen:")

    for warning in warnings:
        print(f"  - {warning}")

    print("Begründung:")
    print(f"  {p.get('reason') or '-'}")

if invalid:
    print("\nNicht lesbare JSON-Dateien:")
    for name, error in invalid:
        print(f"  {name}: {error}")

print("\nBericht abgeschlossen. Keine Dateien verändert.")
PY
