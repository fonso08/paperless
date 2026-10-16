#!/bin/bash
# ============================================================
# 01_gdrive_scan_to_pool.sh
# ============================================================
# Google Drive SCAN -> lokaler Scanpool
#
# v7
#
# Aufgaben:
#   - Dateien rekursiv aus gdrive:SCAN ermitteln
#   - noch nicht bekannte Quellen in den Scanpool kopieren
#   - persistenten v7-Job anlegen
#
# Die Google-Drive-Quelle wird NICHT gelöscht.
#
# SOURCE_PATH und SOURCE_NAME bleiben exakt im Originalzustand.
# Der lokale Dateiname kann dagegen exFAT-kompatibel angepasst
# werden.
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1090
source "${SCRIPT_DIR}/lib/common.sh"

# shellcheck disable=SC1090
source "${SCRIPT_DIR}/lib/jobs.sh"


# ------------------------------------------------------------
# Initialisierung
# ------------------------------------------------------------

init_directories
check_common_requirements
acquire_script_lock

require_command rclone
require_command cmp
require_command dirname
require_command mktemp

info "=== Start 01: Google Drive -> Scanpool ==="

MAX_FILES="${GDRIVE_MAX_FILES_PER_RUN:-0}"

PROCESSED=0
SKIPPED=0
FAILED=0
EXAMINED=0


# ------------------------------------------------------------
# Temporäre Dateiliste
# ------------------------------------------------------------

LIST_FILE="$(mktemp "${TMP_DIR}/gdrive-scan.XXXXXX")"

cleanup() {
    cleanup_tmp_file "${LIST_FILE}"
}

trap cleanup EXIT


# ------------------------------------------------------------
# Google Drive rekursiv auflisten
# ------------------------------------------------------------

if ! rclone lsf -R --files-only "${GDRIVE_SCAN}" > "${LIST_FILE}"; then
    fatal "Google-Drive-Verzeichnis konnte nicht gelesen werden: ${GDRIVE_SCAN}"
fi


# ------------------------------------------------------------
# Dateien verarbeiten
# ------------------------------------------------------------

while IFS= read -r SOURCE_PATH; do

    [[ -n "${SOURCE_PATH}" ]] || continue

    # --------------------------------------------------------
    # Anzahl der untersuchten Dateien begrenzen
    # --------------------------------------------------------

    if (( MAX_FILES > 0 && EXAMINED >= MAX_FILES )); then
        info "Maximale Dateianzahl erreicht: ${MAX_FILES}"
        break
    fi

    EXAMINED=$((EXAMINED + 1))

    SOURCE_NAME="$(basename -- "${SOURCE_PATH}")"

    # Nur die vereinbarten Dokumentformate importieren.
    case "${SOURCE_NAME,,}" in
        *.pdf|*.jpg|*.jpeg|*.png) ;;
        *) info "Ignoriere nicht unterstuetztes Format: ${SOURCE_PATH}"; continue ;;
    esac

    info "Prüfe: ${SOURCE_PATH}"


    # --------------------------------------------------------
    # Bereits vorhandener Job?
    # --------------------------------------------------------

    EXISTING_JOB=""

    if EXISTING_JOB="$(job_find_by_source_path "${SOURCE_PATH}" 2>/dev/null)"; then
        info "Überspringe bereits bekannten Job: ${SOURCE_PATH} (${EXISTING_JOB})"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi


    # --------------------------------------------------------
    # Lokalen Dateinamen exFAT-kompatibel machen
    #
    # SOURCE_NAME bleibt unverändert.
    #
    # ExFAT erlaubt insbesondere keinen Doppelpunkt.
    # Weitere problematische Zeichen werden vorsorglich ersetzt.
    # --------------------------------------------------------

    LOCAL_NAME="${SOURCE_NAME}"

    LOCAL_NAME="${LOCAL_NAME//:/-}"
    LOCAL_NAME="${LOCAL_NAME//\*/-}"
    LOCAL_NAME="${LOCAL_NAME//\?/-}"
    LOCAL_NAME="${LOCAL_NAME//\"/-}"
    LOCAL_NAME="${LOCAL_NAME//</-}"
    LOCAL_NAME="${LOCAL_NAME//>/-}"
    LOCAL_NAME="${LOCAL_NAME//|/-}"

    # --------------------------------------------------------
    # Relative Verzeichnisstruktur von gdrive:SCAN erhalten
    # --------------------------------------------------------

    SOURCE_DIR="$(dirname -- "${SOURCE_PATH}")"

    if [[ "${SOURCE_DIR}" == "." ]]; then
        DEST_FILE="${SCANPOOL_DIR}/${LOCAL_NAME}"
    else
        DEST_FILE="${SCANPOOL_DIR}/${SOURCE_DIR}/${LOCAL_NAME}"
    fi

    DEST_DIR="$(dirname -- "${DEST_FILE}")"

    mkdir -p "${DEST_DIR}"


    # --------------------------------------------------------
    # Bereits vorhandene lokale Datei nicht überschreiben
    # --------------------------------------------------------

    if [[ -e "${DEST_FILE}" ]]; then
        warn "Lokale Datei existiert bereits, aber kein v7-Job:"
        warn "  ${DEST_FILE}"
        warn "Überspringe zur Sicherheit: ${SOURCE_PATH}"

        SKIPPED=$((SKIPPED + 1))
        continue
    fi


    # --------------------------------------------------------
    # Temporärer Dateiname
    #
    # Wichtig:
    # Der temporäre Name enthält KEINE problematischen Zeichen.
    # --------------------------------------------------------

    TMP_FILE="${DEST_FILE}.part.$$"

    rm -f -- "${TMP_FILE}"


    # --------------------------------------------------------
    # Google Drive -> lokaler Scanpool
    # --------------------------------------------------------

    info "Kopiere nach: ${DEST_FILE}"

    if ! rclone copyto \
        "${GDRIVE_SCAN}/${SOURCE_PATH}" \
        "${TMP_FILE}"; then

        rm -f -- "${TMP_FILE}"

        error "Kopieren fehlgeschlagen: ${SOURCE_PATH}"

        FAILED=$((FAILED + 1))
        continue
    fi


    # --------------------------------------------------------
    # Lokale Kopie prüfen
    # --------------------------------------------------------

    if [[ ! -f "${TMP_FILE}" ]]; then
        error "Kopie wurde nicht erzeugt: ${TMP_FILE}"

        rm -f -- "${TMP_FILE}"

        FAILED=$((FAILED + 1))
        continue
    fi


    # --------------------------------------------------------
    # Dateigröße gegen Google Drive prüfen
    #
    # Vollständiger Byte-Vergleich über rclone cat wäre auf
    # dem Raspberry unnötig teuer.
    # --------------------------------------------------------

    SOURCE_SIZE="$(rclone size "${GDRIVE_SCAN}/${SOURCE_PATH}" \
        --json | jq -r '.bytes')"

    LOCAL_SIZE="$(stat -c '%s' -- "${TMP_FILE}")"

    if [[ "${SOURCE_SIZE}" != "${LOCAL_SIZE}" ]]; then
        error "Größenprüfung fehlgeschlagen: ${SOURCE_PATH}"
        error "Google Drive: ${SOURCE_SIZE} Bytes"
        error "Lokal       : ${LOCAL_SIZE} Bytes"

        rm -f -- "${TMP_FILE}"

        FAILED=$((FAILED + 1))
        continue
    fi


    # --------------------------------------------------------
    # Atomar in endgültigen Scanpool-Pfad verschieben
    # --------------------------------------------------------

    mv -f -- "${TMP_FILE}" "${DEST_FILE}"


    # --------------------------------------------------------
    # Job erzeugen
    # --------------------------------------------------------

    if ! JOB_ID="$(job_create \
        "${SOURCE_NAME}" \
        "${DEST_FILE}" \
        "${SOURCE_PATH}")"; then

        error "Job konnte nicht angelegt werden: ${SOURCE_PATH}"

        rm -f -- "${DEST_FILE}"

        FAILED=$((FAILED + 1))
        continue
    fi


    # --------------------------------------------------------
    # Status setzen
    # --------------------------------------------------------

    job_set_status "${JOB_ID}" "COPIED_TO_POOL"

    info "Job ${JOB_ID} angelegt: ${SOURCE_NAME}"

    PROCESSED=$((PROCESSED + 1))

done < "${LIST_FILE}"


# ------------------------------------------------------------
# Ergebnis
# ------------------------------------------------------------

info "=== Ende 01 ==="
info "Untersucht   : ${EXAMINED}"
info "Verarbeitet  : ${PROCESSED}"
info "Übersprungen : ${SKIPPED}"
info "Fehler       : ${FAILED}"

if (( FAILED > 0 )); then
    exit 1
fi

exit 0
