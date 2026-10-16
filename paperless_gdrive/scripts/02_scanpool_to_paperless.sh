#!/bin/bash
# ============================================================
# 02: Genau EIN Dokument aus dem Scanpool an Paperless übergeben
#
# Ablauf:
#   1. Prüfen, ob Paperless aktuell einen Dokument-Task verarbeitet
#   2. Wenn ja -> sofort Ende
#   3. Einen COPIED_TO_POOL Job auswählen
#   4. Genau eine Datei an Paperless übergeben
#   5. Task-ID speichern
#   6. Status auf PAPERLESS_PROCESSING setzen
#   7. SOFORT Ende
#
# Keine Task-Abfrage / kein Polling / keine Archivierung!
# Die komplette Endverarbeitung übernimmt Script 03.
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/jobs.sh"
source "${SCRIPT_DIR}/lib/paperless_api.sh"

init_directories
check_common_requirements
acquire_script_lock

info "=== Start Script 02 ==="

# ------------------------------------------------------------
# Voraussetzungen
# ------------------------------------------------------------

if [[ -z "${PAPERLESS_TOKEN:-}" ]]; then
    error "PAPERLESS_TOKEN ist nicht gesetzt."
    exit 1
fi

# ------------------------------------------------------------
# Prüfen, ob Paperless aktuell einen aktiven Task hat
# ------------------------------------------------------------

paperless_has_active_job() {
    local job_file
    local job_id
    local status
    local task_id
    local task_status

    while IFS= read -r job_file; do
        [[ -f "${job_file}" ]] || continue

        status="$(
            awk -F= '
                $1=="STATUS" {
                    print substr($0,index($0,"=")+1)
                }
            ' "${job_file}"
        )"

        case "${status}" in
            PAPERLESS_SUBMITTED|PAPERLESS_PROCESSING)
                ;;
            *)
                continue
                ;;
        esac

        task_id="$(
            awk -F= '
                $1=="PAPERLESS_TASK_ID" {
                    print substr($0,index($0,"=")+1)
                }
            ' "${job_file}"
        )"

        [[ -n "${task_id}" ]] || continue

        task_status="$(
            paperless_task_status "${task_id}" 2>/dev/null || true
        )"

        task_status="${task_status,,}"

        case "${task_status}" in
            pending|started|retry)
                job_id="$(basename "$(dirname "${job_file}")")"

                info "Paperless verarbeitet aktuell unseren Job."
                info "JOB_ID: ${job_id}"
                info "TASK_ID: ${task_id}"
                info "TASK_STATUS: ${task_status}"

                return 0
                ;;
        esac

    done < <(
        find "${JOB_DIR}" \
            -mindepth 2 \
            -maxdepth 2 \
            -type f \
            -name "job.conf" \
            | sort
    )

    return 1
}

# ------------------------------------------------------------
# Paperless prüfen
# ------------------------------------------------------------

if paperless_has_active_job; then
    info "Kein weiterer Job wird an Paperless übergeben."
    info "=== Ende Script 02 ==="
    exit 0
fi

info "Kein laufender v7-Paperless-Job."

# ------------------------------------------------------------
# Genau EINEN Job mit Status COPIED_TO_POOL auswählen
# ------------------------------------------------------------

JOB_ID=""

while IFS= read -r JOB_FILE; do
    [[ -f "${JOB_FILE}" ]] || continue

    STATUS="$(
        awk -F= '
            $1=="STATUS" {
                print substr($0,index($0,"=")+1)
            }
        ' "${JOB_FILE}"
    )"

    # Eventuelle umschließende Anführungszeichen entfernen.
    STATUS="${STATUS#\"}"
    STATUS="${STATUS%\"}"

    if [[ "${STATUS}" == "COPIED_TO_POOL" ]]; then
        JOB_ID="$(basename "$(dirname "${JOB_FILE}")")"
        break
    fi

done < <(
    find "${JOB_DIR}" \
        -mindepth 2 \
        -maxdepth 2 \
        -type f \
        -name "job.conf" \
        | sort
)

# ------------------------------------------------------------
# Kein Job vorhanden
# ------------------------------------------------------------

if [[ -z "${JOB_ID}" ]]; then
    info "Kein Job mit Status COPIED_TO_POOL vorhanden."
    info "Nichts zu verarbeiten."
    info "=== Ende Script 02 ==="
    exit 0
fi

info "Ausgewählter Job: ${JOB_ID}"

# ------------------------------------------------------------
# Job laden
# ------------------------------------------------------------

job_load "${JOB_ID}"

info "SOURCE_NAME: ${SOURCE_NAME}"
info "SOURCE_PATH: ${SOURCE_PATH}"
info "SOURCE_FILE: ${SOURCE_FILE}"

# ------------------------------------------------------------
# Quelldatei prüfen
# ------------------------------------------------------------

if [[ ! -f "${SOURCE_FILE}" ]]; then
    error "Quelldatei nicht gefunden: ${SOURCE_FILE}"

    job_update "${JOB_ID}" "ERROR_TYPE" "SOURCE_MISSING"
    job_update "${JOB_ID}" "ERROR_MESSAGE" "Quelldatei nicht gefunden: ${SOURCE_FILE}"
    job_update "${JOB_ID}" "FAILED_AT" "$(iso_now)"
    job_set_status "${JOB_ID}" "PAPERLESS_FAILED"

    exit 1
fi

# ------------------------------------------------------------
# Status vor API-Übergabe setzen
# ------------------------------------------------------------

job_set_status "${JOB_ID}" "PAPERLESS_SUBMITTED"

info "Übergebe genau eine Datei an Paperless..."

# ------------------------------------------------------------
# Datei an Paperless senden
# ------------------------------------------------------------

TASK_ID="$(paperless_upload "${SOURCE_FILE}")"

if [[ -z "${TASK_ID}" ]]; then
    error "Paperless hat keine Task-ID zurückgegeben."

    job_update "${JOB_ID}" "ERROR_TYPE" "PAPERLESS_SUBMIT_FAILED"
    job_update "${JOB_ID}" "ERROR_MESSAGE" "Keine Task-ID von Paperless erhalten."
    job_update "${JOB_ID}" "FAILED_AT" "$(iso_now)"
    job_set_status "${JOB_ID}" "PAPERLESS_FAILED"

    exit 1
fi

info "Paperless Task-ID: ${TASK_ID}"

# ------------------------------------------------------------
# Task-ID speichern
# ------------------------------------------------------------

job_update "${JOB_ID}" "PAPERLESS_TASK_ID" "${TASK_ID}"
job_update "${JOB_ID}" "PAPERLESS_STATUS" "pending"

job_set_status "${JOB_ID}" "PAPERLESS_PROCESSING"

info "Datei erfolgreich an Paperless übergeben."
info "Task-ID: ${TASK_ID}"
info "Script 02 wartet NICHT auf die Verarbeitung."
info "Die Endverarbeitung übernimmt Script 03."

info "=== Ende Script 02 ==="

exit 0
