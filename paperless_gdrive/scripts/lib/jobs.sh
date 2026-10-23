#!/bin/bash
# ============================================================
# jobs.sh - Persistente Jobverwaltung für Paperless-GDrive v7
# ============================================================
#
# Aufgabe
# -------
# Diese Library verwaltet ausschließlich den persistenten Zustand
# eines Dokuments innerhalb des v7-Workflows.
#
# Jeder Job liegt in:
#
#   ${JOB_DIR}/<JOB_ID>/job.conf
#
# Die Job-ID ist unsere interne Workflow-ID.
#
# Sie ist ausdrücklich NICHT:
#   - die Paperless Task-ID
#   - die Paperless Dokument-ID
#
# Diese drei IDs werden strikt getrennt gespeichert.
#
# Zustände
# --------
# NEW
# COPIED_TO_POOL
# PAPERLESS_SUBMITTED
# PAPERLESS_PROCESSING
# PAPERLESS_DONE
# PAPERLESS_FAILED
# DUPLICATE
# ARCHIVE_PROCESSING
# ARCHIVE_FAILED
# COMPLETE
#
# Sicherheitsprinzip
# ------------------
# Job-Dateien werden atomar geschrieben:
#
#   temporäre Datei -> mv -> job.conf
#
# Dadurch soll ein Abbruch während des Schreibens keine teilweise
# geschriebene Job-Datei hinterlassen.
# ============================================================

JOBS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=common.sh
source "${JOBS_LIB_DIR}/common.sh"


# ------------------------------------------------------------
# Pfade
# ------------------------------------------------------------

job_dir() {
    local job_id="$1"
    printf '%s/%s\n' "${JOB_DIR}" "${job_id}"
}

job_file() {
    local job_id="$1"
    printf '%s/job.conf\n' "$(job_dir "${job_id}")"
}


# ------------------------------------------------------------
# Job-ID erzeugen
# ------------------------------------------------------------

job_generate_id() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen
    elif [[ -r /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    else
        fatal "Keine Möglichkeit gefunden, eine UUID zu erzeugen."
    fi
}


# ------------------------------------------------------------
# Job erzeugen
#
# Verwendung:
#
#   job_create \
#       "Dateiname.pdf" \
#       "/lokaler/pfad/Dateiname.pdf" \
#       "SCAN/Dateiname.pdf"
#
# Rückgabe auf stdout:
#
#   <JOB_ID>
#
# WICHTIG:
# Nur die Job-ID wird auf stdout ausgegeben, damit die Funktion
# sicher in command substitution verwendet werden kann.
# ------------------------------------------------------------

job_create() {
    local source_name="$1"
    local source_file="$2"
    local source_path="$3"

    [[ -n "${source_name}" ]] ||
        fatal "job_create: SOURCE_NAME fehlt."

    [[ -n "${source_file}" ]] ||
        fatal "job_create: SOURCE_FILE fehlt."

    [[ -n "${source_path}" ]] ||
        fatal "job_create: SOURCE_PATH fehlt."

    [[ -f "${source_file}" ]] ||
        fatal "job_create: Lokale Quelldatei fehlt: ${source_file}"

    local job_id
    local dir
    local file
    local tmp
    local now
    local size
    local mtime

    job_id="$(job_generate_id)"
    dir="$(job_dir "${job_id}")"
    file="$(job_file "${job_id}")"

    mkdir -p "${dir}" || return 1

    tmp="${dir}/.job.conf.tmp.$$"

    now="$(iso_now)"
    size="$(file_size "${source_file}")"
    mtime="$(file_mtime "${source_file}")"

    {
        printf 'JOB_ID=%q\n' "${job_id}"

        printf 'CREATED_AT=%q\n' "${now}"
        printf 'UPDATED_AT=%q\n' "${now}"

        printf 'SOURCE_NAME=%q\n' "${source_name}"
        printf 'SOURCE_FILE=%q\n' "${source_file}"
        printf 'SOURCE_PATH=%q\n' "${source_path}"
        printf 'SOURCE_SIZE=%q\n' "${size}"
        printf 'SOURCE_MTIME=%q\n' "${mtime}"

        printf 'PAPERLESS_TASK_ID=%q\n' ""
        printf 'PAPERLESS_DOCUMENT_ID=%q\n' ""
        printf 'PAPERLESS_STATUS=%q\n' ""

        printf 'PAPERLESS_DUPLICATE=%q\n' "false"
        printf 'PAPERLESS_DUPLICATE_OF=%q\n' ""
        printf 'PAPERLESS_DUPLICATE_IN_TRASH=%q\n' "false"

        printf 'CATEGORY=%q\n' ""

        printf 'ARCHIVE_FILE=%q\n' ""
        printf 'ARCHIVE_TARGET=%q\n' ""
        printf 'ARCHIVE_VERIFIED=%q\n' "false"

        printf 'GDRIVE_SOURCE_DELETED=%q\n' "false"
        printf 'LOCAL_SOURCE_DELETED=%q\n' "false"

        printf 'STATUS=%q\n' "NEW"

        printf 'FAILED_AT=%q\n' ""
        printf 'ERROR_TYPE=%q\n' ""
        printf 'ERROR_MESSAGE=%q\n' ""

        printf 'COMPLETED_AT=%q\n' ""

    } > "${tmp}" || {
        rm -f -- "${tmp}"
        return 1
    }

    mv -f -- "${tmp}" "${file}" || {
        rm -f -- "${tmp}"
        return 1
    }

    printf '%s\n' "${job_id}"
}


# ------------------------------------------------------------
# Job laden
#
# Verwendung:
#
#   job_load "<JOB_ID>"
#
# Danach stehen die Variablen aus job.conf in der aktuellen
# Shell zur Verfügung.
# ------------------------------------------------------------

job_load() {
    local job_id="$1"
    local file

    file="$(job_file "${job_id}")"

    [[ -f "${file}" ]] || {
        error "Job nicht gefunden: ${job_id}"
        return 1
    }

    # Die Datei stammt ausschließlich aus unserem State-Verzeichnis.
    # shellcheck disable=SC1090
    source "${file}"
}


# ------------------------------------------------------------
# Einzelnes Feld atomar aktualisieren
#
# Verwendung:
#
#   job_update JOB_ID KEY VALUE
#
# Es werden ausschließlich einfache KEY=VALUE-Felder verwendet.
# Der Wert wird mit Bash printf %q sicher gespeichert.
# ------------------------------------------------------------

job_update() {
    local job_id="$1"
    local key="$2"
    local value="${3:-}"

    local file
    local tmp
    local replacement

    file="$(job_file "${job_id}")"

    [[ -f "${file}" ]] || {
        error "job_update: Job nicht gefunden: ${job_id}"
        return 1
    }

    [[ "${key}" =~ ^[A-Z][A-Z0-9_]*$ ]] || {
        error "job_update: Ungültiger Schlüssel: ${key}"
        return 1
    }

    printf -v replacement '%s=%q' "${key}" "${value}"

    tmp="$(mktemp "${TMP_DIR}/job-update.XXXXXX")" || return 1

    awk \
        -v key="${key}" \
        -v replacement="${replacement}" '
        BEGIN {
            replaced = 0
        }

        index($0, key "=") == 1 {
            print replacement
            replaced = 1
            next
        }

        {
            print
        }

        END {
            if (!replaced) {
                print replacement
            }
        }
    ' "${file}" > "${tmp}" || {
        rm -f -- "${tmp}"
        return 1
    }

    mv -f -- "${tmp}" "${file}" || {
        rm -f -- "${tmp}"
        return 1
    }

    # Jede fachliche Änderung aktualisiert UPDATED_AT.
    if [[ "${key}" != "UPDATED_AT" ]]; then
        job_update "${job_id}" "UPDATED_AT" "$(iso_now)"
    fi
}


# ------------------------------------------------------------
# Status setzen
# ------------------------------------------------------------

job_set_status() {
    local job_id="$1"
    local status="$2"

    case "${status}" in
        NEW|\
        COPIED_TO_POOL|\
        PAPERLESS_SUBMITTED|\
        PAPERLESS_PROCESSING|\
        GEMINI_PENDING|\
        GEMINI_FAILED|\
        GEMINI_SKIPPED|\
        QUARANTINE|\
        REVIEW_APPROVED|\
        PAPERLESS_DONE|\
        PAPERLESS_FAILED|\
        DUPLICATE|\
        ARCHIVE_PROCESSING|\
        ARCHIVE_FAILED|\
        COMPLETE)
            ;;
        *)
            error "Ungültiger Job-Status: ${status}"
            return 1
            ;;
    esac

    job_update "${job_id}" "STATUS" "${status}"
}


# ------------------------------------------------------------
# Job anhand des Google-Drive-Quellpfads suchen
#
# SOURCE_PATH ist innerhalb unseres Workflows die stabilere
# Identität als nur der Dateiname.
#
# Rückgabe:
#   stdout = JOB_ID
#   rc 0   = gefunden
#   rc 1   = nicht gefunden
# ------------------------------------------------------------

job_find_by_source_path() {
    local source_path="$1"
    local file

    while IFS= read -r -d '' file; do

        (
            # shellcheck disable=SC1090
            source "${file}"

            if [[ "${SOURCE_PATH:-}" == "${source_path}" ]]; then
                printf '%s\n' "${JOB_ID}"
                exit 0
            fi

            exit 1
        ) && return 0

    done < <(
        find "${JOB_DIR}" \
            -mindepth 2 \
            -maxdepth 2 \
            -type f \
            -name job.conf \
            -print0
    )

    return 1
}


# ------------------------------------------------------------
# Job anhand des Dateinamens suchen
#
# Diese Funktion dient nur Diagnose/Komfort.
# Für die Workflow-Identität bevorzugen wir SOURCE_PATH.
# ------------------------------------------------------------

job_find_by_source_name() {
    local source_name="$1"
    local file

    while IFS= read -r -d '' file; do

        (
            # shellcheck disable=SC1090
            source "${file}"

            if [[ "${SOURCE_NAME:-}" == "${source_name}" ]]; then
                printf '%s\n' "${JOB_ID}"
                exit 0
            fi

            exit 1
        ) && return 0

    done < <(
        find "${JOB_DIR}" \
            -mindepth 2 \
            -maxdepth 2 \
            -type f \
            -name job.conf \
            -print0
    )

    return 1
}


# ------------------------------------------------------------
# Statusklassen
# ------------------------------------------------------------

job_is_terminal() {
    local status="$1"

    case "${status}" in
        COMPLETE|DUPLICATE|PAPERLESS_FAILED)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}


job_is_active() {
    local status="$1"

    case "${status}" in
        NEW|\
        COPIED_TO_POOL|\
        PAPERLESS_SUBMITTED|\
        PAPERLESS_PROCESSING|\
        GEMINI_PENDING|\
        GEMINI_FAILED|\
        GEMINI_SKIPPED|\
        QUARANTINE|\
        REVIEW_APPROVED|\
        PAPERLESS_DONE|\
        ARCHIVE_PROCESSING|\
        ARCHIVE_FAILED)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}


# ------------------------------------------------------------
# Anzahl aktiver Jobs
# ------------------------------------------------------------

job_count_active() {
    local file
    local count=0

    while IFS= read -r -d '' file; do

        (
            # shellcheck disable=SC1090
            source "${file}"
            job_is_active "${STATUS:-}"
        ) && count=$((count + 1))

    done < <(
        find "${JOB_DIR}" \
            -mindepth 2 \
            -maxdepth 2 \
            -type f \
            -name job.conf \
            -print0
    )

    printf '%s\n' "${count}"
}


# ------------------------------------------------------------
# Jobliste
# ------------------------------------------------------------

job_list() {
    local file

    printf '%-36s  %-22s  %-10s  %s\n' \
        "JOB_ID" \
        "STATUS" \
        "DOC_ID" \
        "SOURCE"

    printf '%-36s  %-22s  %-10s  %s\n' \
        "------------------------------------" \
        "----------------------" \
        "----------" \
        "------------------------------"

    while IFS= read -r -d '' file; do

        (
            # shellcheck disable=SC1090
            source "${file}"

            printf '%-36s  %-22s  %-10s  %s\n' \
                "${JOB_ID:-?}" \
                "${STATUS:-?}" \
                "${PAPERLESS_DOCUMENT_ID:--}" \
                "${SOURCE_NAME:-?}"
        )

    done < <(
        find "${JOB_DIR}" \
            -mindepth 2 \
            -maxdepth 2 \
            -type f \
            -name job.conf \
            -print0 |
        sort -z
    )
}
