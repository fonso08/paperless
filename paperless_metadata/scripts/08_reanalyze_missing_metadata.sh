#!/usr/bin/env bash
set -uo pipefail

# Fehlende Gemini-Proposals in Batches erstellen.
# Bestehende Proposals werden durch 01_analyze.sh geschützt.
# Keine Paperless-Metadatenänderungen und keine GDrive-Archivierung.

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

source "$ROOT/scripts/lib/paperless_api.sh"
source "$ROOT/scripts/lib/llm_api.sh"

BATCH_SIZE=10
PAUSE_SECONDS=300
PROPOSALS="$PM_STATE/proposals"

pm_init

if [[ -z "${PAPERLESS_TOKEN:-}" || -z "${GEMINI_API_KEY:-}" ]]; then
    echo "FEHLER: PAPERLESS_TOKEN oder GEMINI_API_KEY fehlt." >&2
    exit 2
fi

# Die konfigurierte API-Obergrenze beachten.
if (( LLM_MAX_REQUESTS_PER_RUN < BATCH_SIZE )); then
    BATCH_SIZE="$LLM_MAX_REQUESTS_PER_RUN"
fi

if (( BATCH_SIZE < 1 )); then
    echo "FEHLER: Ungültiges API-Limit: $BATCH_SIZE" >&2
    exit 2
fi

mkdir -p "$PROPOSALS"

count_valid_proposals() {
    local file count=0
    while IFS= read -r -d '' file; do
        if jq -e . "$file" >/dev/null 2>&1; then
            ((count+=1))
        fi
    done < <(find "$PROPOSALS" -maxdepth 1 -type f -name '*.json' -print0)
    printf '%s\n' "$count"
}

batch=0
total_new=0

echo "=== Gemini: Fehlende Proposals ==="
echo "Batchgröße: $BATCH_SIZE"
echo "Pause:      $PAUSE_SECONDS Sekunden"
echo "Ziel:       $PROPOSALS"
echo "Modus:      nur Analyse, keine Paperless-Änderungen"
echo

while true; do
    batch=$((batch + 1))
    before="$(count_valid_proposals)"

    echo "=== Batch $batch ==="

    if "$ROOT/scripts/01_analyze.sh" --missing "$BATCH_SIZE"; then
        analyzer_rc=0
    else
        analyzer_rc=$?
        echo "WARNUNG: Analyse meldete Exitcode $analyzer_rc."
    fi

    after="$(count_valid_proposals)"
    new=$((after - before))

    echo "Neue gültige Proposal-Dateien: $new"
    total_new=$((total_new + (new > 0 ? new : 0)))

    if (( new <= 0 )); then
        echo "Keine Zunahme gültiger Proposals; Batch-Verarbeitung wird beendet."
        break
    fi

    echo "Bisherige Zunahme: $total_new"
    echo "Pause: 3 Minuten"
    sleep "$PAUSE_SECONDS"
done

echo
echo "=== Fertig ==="
echo "Durchläufe:             $batch"
echo "Neue gültige Proposals: $total_new"
echo "Paperless geändert:     NEIN"
echo "Google Drive archiviert: NEIN"
