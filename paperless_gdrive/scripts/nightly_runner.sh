#!/bin/bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

LOG_DIR="/media/BlueDisc3/PAPERLESS/logs"
LOG_FILE="${LOG_DIR}/paperless-gdrive-nightly.log"

mkdir -p "${LOG_DIR}"

timestamp() {
    date '+%Y-%m-%d %H:%M:%S%z'
}

log() {
    printf '%s [NIGHTLY] %s\n' "$(timestamp)" "$*" | tee -a "${LOG_FILE}"
}

run_script() {
    local script="$1"

    log "Starte ${script}"

    if "${SCRIPT_DIR}/${script}" >>"${LOG_FILE}" 2>&1; then
        log "${script} erfolgreich beendet."
    else
        local rc=$?
        log "${script} beendet mit Fehlercode ${rc}."
    fi
}

log "============================================================"
log "=== Nightly Runner gestartet ==="

run_script "01_gdrive_scan_to_pool.sh"
run_script "02_scanpool_to_paperless.sh"
run_script "03_archive_to_gdrive.sh"

log "=== Nightly Runner beendet ==="
log "============================================================"
