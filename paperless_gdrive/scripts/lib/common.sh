#!/bin/bash
# ============================================================
# common.sh - Allgemeine Hilfsfunktionen
# ============================================================
# Verantwortlich für:
#   - Konfiguration laden
#   - Verzeichnisse prüfen/anlegen
#   - Logging
#   - Basis-Prüfungen
#   - einfache Lock-/Status-Hilfen
#
# Keine Paperless-spezifische oder Job-spezifische Logik.
# ============================================================

set -o pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$(cd "${LIB_DIR}/.." && pwd)"
DEFAULT_BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${DEFAULT_BASE_DIR}/config/paperless-gdrive.conf"

# ============================================================
# Geschützte Secrets laden
# ============================================================
PAPERLESS_SECRET_FILE="/home/pi/.config/paperless-gdrive/paperless.env"

if [[ -r "${PAPERLESS_SECRET_FILE}" ]]; then
    set -a
    source "${PAPERLESS_SECRET_FILE}"
    set +a
fi

if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "FEHLER: Konfiguration nicht gefunden: ${CONFIG_FILE}" >&2
    return 1 2>/dev/null || exit 1
fi

# shellcheck disable=SC1090
source "${CONFIG_FILE}"

: "${LOG_DIR:=/media/BlueDisc3/logs}"
: "${STATE_DIR:=${BASE_DIR}/state}"
: "${JOB_DIR:=${STATE_DIR}/jobs}"
: "${TMP_DIR:=${STATE_DIR}/tmp}"
: "${ACTIVE_JOB_FILE:=${STATE_DIR}/active_job}"

# Name des aufrufenden Hauptscripts bestimmen.
#
# Bei "source common.sh" in einer interaktiven Shell kann $0 z. B. "-bash"
# sein. Das führende "--" verhindert, dass basename dies als Option
# interpretiert.
SCRIPT_BASENAME="$(basename -- "${0}")"

# Für interaktive Tests keinen ungültigen Script-Namen als Logname verwenden.
case "${SCRIPT_BASENAME}" in
    bash|-bash|sh|-sh)
        SCRIPT_BASENAME="interactive"
        SCRIPT_NUMBER="test"
        ;;
    *)
        SCRIPT_NUMBER="${SCRIPT_BASENAME%%_*}"
        ;;
esac

LOG_FILE="${LOG_DIR}/paperless-gdrive-${SCRIPT_NUMBER}.log"

mkdir -p "${LOG_DIR}" "${STATE_DIR}" "${JOB_DIR}" "${TMP_DIR}" "${SCANPOOL_DIR}"

timestamp() {
    date '+%Y-%m-%d %H:%M:%S%z'
}

log() {
    local level="$1"; shift
    local message="$*"
    local line="$(timestamp) [${level}] [${SCRIPT_BASENAME}] ${message}"
    printf '%s\n' "${line}" | tee -a "${LOG_FILE}"
}

info()    { log INFO "$@"; }
warn()    { log WARN "$@"; }
warning() { warn "$@"; }
error()   { log ERROR "$@" >&2; }

fatal() {
    error "$@"
    exit 1
}

require_command() {
    local cmd="$1"
    command -v "${cmd}" >/dev/null 2>&1 || fatal "Benötigtes Kommando fehlt: ${cmd}"
}

require_env() {
    local name="$1"
    [[ -n "${!name:-}" ]] || fatal "Umgebungsvariable ${name} ist nicht gesetzt."
}

require_directory() {
    local dir="$1"
    [[ -d "${dir}" ]] || fatal "Verzeichnis fehlt: ${dir}"
}

require_writable_directory() {
    local dir="$1"
    require_directory "${dir}"
    [[ -w "${dir}" ]] || fatal "Verzeichnis ist nicht beschreibbar: ${dir}"
}

init_directories() {
    mkdir -p \
        "${LOG_DIR}" \
        "${STATE_DIR}" \
        "${JOB_DIR}" \
        "${TMP_DIR}" \
        "${SCANPOOL_DIR}"
}

check_common_requirements() {
    require_command date
    require_command find
    require_command awk
    require_command sed
    require_command grep
    require_command mktemp
    require_directory "${PAPERLESS_DATA_DIR}"
    require_writable_directory "${SCANPOOL_DIR}"
    require_writable_directory "${STATE_DIR}"
    require_writable_directory "${JOB_DIR}"
    require_writable_directory "${TMP_DIR}"
    require_writable_directory "${LOG_DIR}"
}

# Verhindert, dass zwei Instanzen desselben Scripts gleichzeitig laufen.
# Der Lock bleibt nicht als fachlicher Job-State bestehen.
acquire_script_lock() {
    local lock_file="${STATE_DIR}/.${SCRIPT_BASENAME}.lock"
    exec 9>"${lock_file}"
    if ! flock -n 9; then
        info "Eine Instanz von ${SCRIPT_BASENAME} läuft bereits."
        exit 0
    fi
}

cleanup_tmp_file() {
    local file="$1"
    [[ -n "${file}" ]] && [[ -e "${file}" ]] && rm -f -- "${file}"
}

safe_basename() {
    basename -- "$1"
}

file_size() {
    stat -c '%s' -- "$1"
}

file_mtime() {
    stat -c '%Y' -- "$1"
}

iso_now() {
    date --iso-8601=seconds
}
