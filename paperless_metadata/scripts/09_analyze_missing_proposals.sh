#!/usr/bin/env bash
set -u

# Gemini-Analyse fehlender Proposals in Batches
# Bestehende Skripte werden nicht verändert.
# Keine Änderungen an Paperless-Metadaten, keine GDrive-Archivierung.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PM_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
ANALYZER="$PM_ROOT/scripts/01_analyze.sh"
PROPOSAL_DIR="$PM_ROOT/state/proposals"
BATCH_SIZE=10
PAUSE_SECONDS=180

if [[ ! -x "$ANALYZER" ]]; then
    echo "FEHLER: Analyse-Skript fehlt oder ist nicht ausführbar: $ANALYZER" >&2
    exit 1
fi

if [[ ! -d "$PROPOSAL_DIR" ]]; then
    echo "FEHLER: Proposal-Verzeichnis nicht gefunden: $PROPOSAL_DIR" >&2
    exit 1
fi

count_proposals() {
    find "$PROPOSAL_DIR" -maxdepth 1 -type f -name '*.json' | wc -l
}

echo "============================================================"
echo "Gemini: Fehlende Proposals erstellen"
echo "============================================================"
echo "Projekt:       $PM_ROOT"
echo "Batchgröße:    $BATCH_SIZE"
echo "Pause:         $PAUSE_SECONDS Sekunden"
echo "Modus:         Analyse, keine Metadatenänderung"
echo

batch=0
total_new=0

while true; do
    batch=$((batch + 1))
    before="$(count_proposals)"

    echo "=== Durchlauf $batch ==="
    echo "Vorhandene Proposals: $before"

    # Vorhandenes Analyse-Skript verwenden, nicht selbst klassifizieren.
    "$ANALYZER" --missing "$BATCH_SIZE"
    analyzer_rc=$?

    after="$(count_proposals)"
    new=$((after - before))

    echo "Neue Proposals in diesem Durchlauf: $new"
    echo "Analyse-Exitcode: $analyzer_rc"

    if (( new > 0 )); then
        total_new=$((total_new + new))
    else
        echo
        echo "Keine neuen Proposals erzeugt."
        echo "Ende, damit fehlgeschlagene Dokumente nicht endlos wiederholt werden."
        break
    fi

    echo "Bisher neu erstellt: $total_new"

    echo "Pause für 3 Minuten ..."
    sleep "$PAUSE_SECONDS"
    echo
done

echo "============================================================"
echo "Abgeschlossen"
echo "Durchläufe:             $batch"
echo "Neue Proposals gesamt:  $total_new"
echo "============================================================"

exit 0
