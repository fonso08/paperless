#!/bin/bash
# ============================================================
# 00: Recovery verlorener v7-Jobs aus dem vorhandenen Scanpool
#
# Zweck:
#   Nach einem Verlust der state/jobs/*.job.conf können bereits
#   vorhandene Dateien im Scanpool wieder als v7-Jobs registriert
#   werden.
#
# Verhalten:
#   - verarbeitet PDF, JPG, JPEG und PNG
#   - berücksichtigt Unterverzeichnisse rekursiv
#   - erstellt nur fehlende Jobs
#   - setzt neue Jobs direkt auf COPIED_TO_POOL
#   - verändert keine Dateien im Scanpool
#   - löscht nichts aus Google Drive
#   - löscht nichts lokal
#   - kann beliebig oft erneut ausgeführt werden
#
# Projekt:
#   /home/pi/docker/paperless/paperless_gdrive
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/jobs.sh"

init_directories
check_common_requirements

info "=== Start Script 00 – Recovery Scanpool Jobs ==="

CREATED=0
EXISTING=0
FAILED=0
TOTAL=0
SKIPPED_UNSUPPORTED=0

RECOVERY_ROOT="${SCANPOOL_DIR}"

if [[ ! -d "${RECOVERY_ROOT}" ]]; then
    error "Scanpool-Verzeichnis nicht gefunden: ${RECOVERY_ROOT}"
    exit 1
fi

# ------------------------------------------------------------
# Prüfen, ob für SOURCE_FILE bereits ein Job existiert.
#
# job_create schreibt SOURCE_FILE mit printf '%q'.
# Deshalb vergleichen wir ebenfalls mit printf '%q'.
# ------------------------------------------------------------
job_exists_for_source_file() {
    local source_file="$1"
    local encoded

    encoded="$(printf '%q' "${source_file}")"

    while IFS= read -r job_file; do
        [[ -f "${job_file}" ]] || continue

        if grep -Fqx "SOURCE_FILE=${encoded}" "${job_file}"; then
            return 0
        fi
    done < <(
        find "${JOB_DIR}" \
            -mindepth 2 \
            -maxdepth 2 \
            -type f \
            -name "job.conf" \
            2>/dev/null
    )

    return 1
}

# ------------------------------------------------------------
# Nur Paperless-relevante Dateitypen aufnehmen.
# ------------------------------------------------------------
is_supported_recovery_file() {
    local file="$1"
    local name
    local ext

    name="$(basename -- "${file}")"

    if [[ "${name}" != *.* ]]; then
        return 1
    fi

    ext="${name##*.}"
    ext="${ext,,}"

    case "${ext}" in
        pdf|jpg|jpeg|png)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# ------------------------------------------------------------
# Scanpool rekursiv durchsuchen.
# Sortierung sorgt für reproduzierbare Reihenfolge.
# ------------------------------------------------------------
while IFS= read -r -d '' SOURCE_FILE; do

    TOTAL=$((TOTAL + 1))

    if ! is_supported_recovery_file "${SOURCE_FILE}"; then
        SKIPPED_UNSUPPORTED=$((SKIPPED_UNSUPPORTED + 1))
        continue
    fi

    # Sicherheit: Datei muss tatsächlich existieren.
    if [[ ! -f "${SOURCE_FILE}" ]]; then
        error "Datei verschwunden: ${SOURCE_FILE}"
        FAILED=$((FAILED + 1))
        continue
    fi

    # Bereits vorhandenen Job nicht erneut erzeugen.
    if job_exists_for_source_file "${SOURCE_FILE}"; then
        EXISTING=$((EXISTING + 1))
        continue
    fi

    # Relativer Pfad innerhalb des Scanpools.
    SOURCE_PATH="${SOURCE_FILE#${RECOVERY_ROOT}/}"

    # Dateiname ohne Verzeichnisse.
    SOURCE_NAME="$(basename -- "${SOURCE_FILE}")"

    info "Recovery: ${SOURCE_PATH}"

    if ! JOB_ID="$(
        job_create \
            "${SOURCE_NAME}" \
            "${SOURCE_FILE}" \
            "${SOURCE_PATH}"
    )"; then
        error "Job konnte nicht erzeugt werden: ${SOURCE_PATH}"
        FAILED=$((FAILED + 1))
        continue
    fi

    if ! job_set_status "${JOB_ID}" "COPIED_TO_POOL"; then
        error "Status konnte nicht gesetzt werden: ${JOB_ID}"
        FAILED=$((FAILED + 1))
        continue
    fi

    CREATED=$((CREATED + 1))

    info "  Job: ${JOB_ID}"
    info "  Status: COPIED_TO_POOL"

done < <(
    find "${RECOVERY_ROOT}" \
        -type f \
        -print0 |
    sort -z
)

echo
info "===== Recovery-Zusammenfassung ====="
info "Gefundene Dateien:        ${TOTAL}"
info "Neue Jobs erstellt:       ${CREATED}"
info "Bereits vorhandene Jobs:  ${EXISTING}"
info "Nicht berücksichtigt:     ${SKIPPED_UNSUPPORTED}"
info "Fehler:                   ${FAILED}"

if [[ "${FAILED}" -gt 0 ]]; then
    error "Recovery mit Fehlern beendet."
    exit 1
fi

info "Recovery erfolgreich abgeschlossen."
info "=== Ende Script 00 ==="
