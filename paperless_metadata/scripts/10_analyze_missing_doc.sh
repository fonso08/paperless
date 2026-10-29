#!/usr/bin/env bash
set -uo pipefail

# Projektverzeichnis bestimmen
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR" || exit 1

BATCH_SIZE=10
ROUND=0
LOG_FILE="$(mktemp "${TMPDIR:-/tmp}/paperless-analyze-all.XXXXXX")"
trap 'rm -f "$LOG_FILE"' EXIT

echo "=== Analyse aller fehlenden Vorschläge gestartet ==="
echo "Batchgröße: $BATCH_SIZE"
echo "Projekt: $PROJECT_DIR"
echo

while true; do
    ((ROUND+=1))
    echo "===== Durchlauf $ROUND ====="

    # Ausgabe live anzeigen und gleichzeitig zur Auswertung speichern.
    ./scripts/01_analyze_doc.sh --missing "$BATCH_SIZE" 2>&1 | tee "$LOG_FILE"
    STATUS=${PIPESTATUS[0]}

    if (( STATUS != 0 )); then
        echo
        echo "FEHLER: Analyse-Durchlauf $ROUND endete mit Status $STATUS."
        echo "Abbruch, damit Fehler nicht endlos wiederholt werden."
        exit "$STATUS"
    fi

    SELECTED="$(
    sed -n \
      's/.*Fehlende Vorschläge\( ohne noLLM\)\? ausgewählt: \([0-9][0-9]*\).*/\2/p' \
      "$LOG_FILE" | tail -n 1
    )"

    if [[ ! "$SELECTED" =~ ^[0-9]+$ ]]; then
        echo "FEHLER: Anzahl fehlender Vorschläge konnte nicht ermittelt werden."
        exit 1
    fi

    if (( SELECTED == 0 )); then
        echo
        echo "=== Fertig: Keine fehlenden Vorschläge mehr gefunden. ==="
        echo "Durchläufe insgesamt: $ROUND"
        exit 0
    fi

    echo
    echo "Durchlauf $ROUND erfolgreich; $SELECTED Dokument(e) wurden ausgewählt."
    echo "Der nächste Durchlauf startet in 2 Sekunden."
    sleep 2
    echo
done
