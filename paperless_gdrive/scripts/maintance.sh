#!/bin/bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/jobs.sh"


# ============================================================
# Hilfsfunktion: Wert aus job.conf lesen
# ============================================================

get_job_value() {
    local job_file="$1"
    local key="$2"

    local value

    value="$(
        awk -F= -v key="${key}" '
            $1 == key {
                print substr($0, index($0, "=") + 1)
                exit
            }
        ' "${job_file}"
    )"

    value="${value#\"}"
    value="${value%\"}"

    printf '%s\n' "${value}"
}


# ============================================================
# Jobs und Status anzeigen
# ============================================================

show_jobs() {
    echo
    echo "============================================================"
    echo " Jobs und Status"
    echo "============================================================"

    local count=0
    local job_file
    local job_id
    local status
    local source_name

    for job_file in "${JOB_DIR}"/*/job.conf; do
        [[ -f "${job_file}" ]] || continue

        count=$((count + 1))

        job_id="$(basename "$(dirname "${job_file}")")"
        status="$(get_job_value "${job_file}" "STATUS")"
        source_name="$(get_job_value "${job_file}" "SOURCE_NAME")"

        printf '%-38s %-22s %s\n' \
            "${job_id}" \
            "${status}" \
            "${source_name}"
    done

    echo
    echo "------------------------------------------------------------"
    echo "Anzahl Jobs: ${count}"
    echo "------------------------------------------------------------"
    echo
}


# ============================================================
# Dokumente nach Status anzeigen
# ============================================================

show_jobs_by_status() {
    local wanted_status="$1"

    echo
    echo "============================================================"
    echo " Dokumente mit Status: ${wanted_status}"
    echo "============================================================"

    local count=0
    local job_file
    local job_id
    local status
    local source_name
    local source_path
    local paperless_document_id
    local duplicate_of
    local duplicate_in_trash
    local error_type
    local error_message
    local archive_target

    for job_file in "${JOB_DIR}"/*/job.conf; do
        [[ -f "${job_file}" ]] || continue

        status="$(get_job_value "${job_file}" "STATUS")"

        if [[ "${wanted_status}" != "ALL" && "${status}" != "${wanted_status}" ]]; then
            continue
        fi

        count=$((count + 1))

        job_id="$(basename "$(dirname "${job_file}")")"

        source_name="$(get_job_value "${job_file}" "SOURCE_NAME")"
        source_path="$(get_job_value "${job_file}" "SOURCE_PATH")"

        paperless_document_id="$(
            get_job_value "${job_file}" "PAPERLESS_DOCUMENT_ID"
        )"

        duplicate_of="$(
            get_job_value "${job_file}" "PAPERLESS_DUPLICATE_OF"
        )"

        duplicate_in_trash="$(
            get_job_value "${job_file}" "PAPERLESS_DUPLICATE_IN_TRASH"
        )"

        error_type="$(get_job_value "${job_file}" "ERROR_TYPE")"
        error_message="$(get_job_value "${job_file}" "ERROR_MESSAGE")"

        archive_target="$(get_job_value "${job_file}" "ARCHIVE_TARGET")"

        echo
        echo "------------------------------------------------------------"
        echo "Job:              ${job_id}"
        echo "Status:           ${status}"
        echo "Datei:            ${source_name}"
        echo "Quelle:           ${source_path}"

        case "${status}" in

            DUPLICATE)
                echo "Duplikat von:     ${duplicate_of:-unbekannt}"
                echo "Im Papierkorb:    ${duplicate_in_trash:-unbekannt}"
                ;;

            PAPERLESS_FAILED)
                echo "Fehlertyp:        ${error_type:-unbekannt}"
                echo "Fehler:"
                echo "  ${error_message:-unbekannt}"
                ;;

            ARCHIVE_FAILED)
                echo "Archivziel:       ${archive_target:-unbekannt}"
                echo "Fehlertyp:        ${error_type:-unbekannt}"
                echo "Fehler:"
                echo "  ${error_message:-unbekannt}"
                ;;

            COMPLETE)
                echo "Paperless-ID:     ${paperless_document_id:-unbekannt}"
                echo "Archivziel:       ${archive_target:-unbekannt}"
                ;;

            PAPERLESS_PROCESSING|PAPERLESS_SUBMITTED)
                echo "Paperless-ID:     ${paperless_document_id:-noch nicht vorhanden}"
                ;;

            *)
                if [[ -n "${paperless_document_id}" ]]; then
                    echo "Paperless-ID:     ${paperless_document_id}"
                fi
                ;;
        esac
    done

    echo
    echo "============================================================"
    echo "Gefundene Jobs: ${count}"
    echo "============================================================"
    echo
}


# ============================================================
# Statistik
# ============================================================

show_statistics() {
    echo
    echo "============================================================"
    echo " Statistik"
    echo "============================================================"

    local total=0
    local complete=0
    local duplicate=0
    local paperless_failed=0
    local archive_failed=0
    local processing=0
    local submitted=0
    local other=0

    local job_file
    local status

    for job_file in "${JOB_DIR}"/*/job.conf; do
        [[ -f "${job_file}" ]] || continue

        total=$((total + 1))
        status="$(get_job_value "${job_file}" "STATUS")"

        case "${status}" in
            COMPLETE)
                complete=$((complete + 1))
                ;;
            DUPLICATE)
                duplicate=$((duplicate + 1))
                ;;
            PAPERLESS_FAILED)
                paperless_failed=$((paperless_failed + 1))
                ;;
            ARCHIVE_FAILED)
                archive_failed=$((archive_failed + 1))
                ;;
            PAPERLESS_PROCESSING)
                processing=$((processing + 1))
                ;;
            PAPERLESS_SUBMITTED)
                submitted=$((submitted + 1))
                ;;
            *)
                other=$((other + 1))
                ;;
        esac
    done

    local scanpool_count=0

    if [[ -d "${SCANPOOL_DIR}" ]]; then
        scanpool_count="$(
            find "${SCANPOOL_DIR}" \
                -mindepth 1 \
                -maxdepth 1 \
                -type f \
                | wc -l
        )"
    fi

    echo
    printf '%-28s %s\n' "Jobs gesamt:" "${total}"
    printf '%-28s %s\n' "COMPLETE:" "${complete}"
    printf '%-28s %s\n' "DUPLICATE:" "${duplicate}"
    printf '%-28s %s\n' "PAPERLESS_FAILED:" "${paperless_failed}"
    printf '%-28s %s\n' "ARCHIVE_FAILED:" "${archive_failed}"
    printf '%-28s %s\n' "PAPERLESS_PROCESSING:" "${processing}"
    printf '%-28s %s\n' "PAPERLESS_SUBMITTED:" "${submitted}"
    printf '%-28s %s\n' "Sonstige:" "${other}"
    echo
    printf '%-28s %s\n' "Dateien im Scanpool:" "${scanpool_count}"

    echo
    echo "------------------------------------------------------------"

    if (( paperless_failed > 0 )); then
        echo "WARNUNG: Paperless-Fehler vorhanden."
    fi

    if (( archive_failed > 0 )); then
        echo "WARNUNG: Archivierungsfehler vorhanden."
    fi

    if (( processing > 0 || submitted > 0 )); then
        echo "HINWEIS: Jobs befinden sich noch in Verarbeitung."
    fi

    if (( paperless_failed == 0 &&
          archive_failed == 0 &&
          processing == 0 &&
          submitted == 0 )); then
        echo "Keine auffälligen Status gefunden."
    fi

    echo "------------------------------------------------------------"
    echo
}


# ============================================================
# System- und Konfigurationsprüfung
# ============================================================

system_check() {
    echo
    echo "============================================================"
    echo " System- und Konfigurationsprüfung"
    echo "============================================================"
    echo

    local errors=0
    local warnings=0

    check_dir() {
        local name="$1"
        local dir="$2"

        if [[ -d "${dir}" ]]; then
            echo "[OK]   ${name}: ${dir}"
        else
            echo "[FEHLER] ${name} fehlt: ${dir}"
            errors=$((errors + 1))
        fi
    }

    check_file() {
        local name="$1"
        local file="$2"

        if [[ -f "${file}" ]]; then
            echo "[OK]   ${name}: ${file}"
        else
            echo "[WARN] ${name} fehlt: ${file}"
            warnings=$((warnings + 1))
        fi
    }

    echo "Verzeichnisse:"
    check_dir "BASE_DIR" "${BASE_DIR}"
    check_dir "JOB_DIR" "${JOB_DIR}"
    check_dir "SCANPOOL_DIR" "${SCANPOOL_DIR}"

    echo
    echo "Dateien:"
    check_file "ACTIVE_JOB_FILE" "${ACTIVE_JOB_FILE}"

    echo
    echo "Umgebungsvariablen:"

    if [[ -n "${PAPERLESS_TOKEN:-}" ]]; then
        echo "[OK]   PAPERLESS_TOKEN ist gesetzt"
    else
        echo "[WARN] PAPERLESS_TOKEN ist NICHT gesetzt"
        warnings=$((warnings + 1))
    fi

    echo
    echo "Programme:"

    if command -v rclone >/dev/null 2>&1; then
        echo "[OK]   rclone: $(rclone version 2>/dev/null | head -n 1)"
    else
        echo "[FEHLER] rclone nicht gefunden"
        errors=$((errors + 1))
    fi

    if command -v curl >/dev/null 2>&1; then
        echo "[OK]   curl vorhanden"
    else
        echo "[FEHLER] curl nicht gefunden"
        errors=$((errors + 1))
    fi

    echo
    echo "Paperless API:"

    if [[ -n "${PAPERLESS_TOKEN:-}" ]]; then

        local http_code

        http_code="$(
            curl -s \
                -o /dev/null \
                -w '%{http_code}' \
                --max-time 10 \
                --header "Authorization: Token ${PAPERLESS_TOKEN}" \
                --header "Accept: application/json; version=${PAPERLESS_API_VERSION}" \
                "${PAPERLESS_URL}/api/"
        )"

        if [[ "${http_code}" == "200" ]]; then
            echo "[OK]   Paperless API erreichbar (${PAPERLESS_URL})"
        elif [[ "${http_code}" == "401" ]]; then
            echo "[FEHLER] Paperless API: HTTP 401 - Token ungültig"
            errors=$((errors + 1))
        elif [[ "${http_code}" =~ ^[0-9]+$ ]]; then
            echo "[WARN] Paperless API antwortet mit HTTP ${http_code}"
            warnings=$((warnings + 1))
        else
            echo "[FEHLER] Paperless API nicht erreichbar"
            errors=$((errors + 1))
        fi

    else
        echo "[ÜBERSPRUNGEN] Kein PAPERLESS_TOKEN vorhanden"
    fi

    echo
    echo "------------------------------------------------------------"
    echo "Ergebnis:"
    echo "  Fehler:   ${errors}"
    echo "  Warnungen:${warnings}"
    echo "------------------------------------------------------------"
    echo
}


# ============================================================
# Job-Integritätsprüfung
# ============================================================

check_job_integrity() {
    echo
    echo "============================================================"
    echo " Job-Integritätsprüfung"
    echo "============================================================"
    echo

    local total=0
    local errors=0
    local warnings=0

    local job_file
    local job_id
    local status
    local source_name
    local source_path
    local paperless_document_id
    local archive_target

    for job_file in "${JOB_DIR}"/*/job.conf; do
        [[ -f "${job_file}" ]] || continue

        total=$((total + 1))

        job_id="$(basename "$(dirname "${job_file}")")"

        status="$(get_job_value "${job_file}" "STATUS")"
        source_name="$(get_job_value "${job_file}" "SOURCE_NAME")"
        source_path="$(get_job_value "${job_file}" "SOURCE_PATH")"
        paperless_document_id="$(
            get_job_value "${job_file}" "PAPERLESS_DOCUMENT_ID"
        )"
        archive_target="$(get_job_value "${job_file}" "ARCHIVE_TARGET")"

        # ----------------------------------------------------
        # JOB_ID prüfen
        # ----------------------------------------------------

        local stored_job_id
        stored_job_id="$(get_job_value "${job_file}" "JOB_ID")"

        if [[ -z "${stored_job_id}" ]]; then
            echo "[FEHLER] ${job_id}: JOB_ID fehlt"
            errors=$((errors + 1))
        elif [[ "${stored_job_id}" != "${job_id}" ]]; then
            echo "[FEHLER] ${job_id}: JOB_ID stimmt nicht mit Verzeichnis überein"
            errors=$((errors + 1))
        fi

        # ----------------------------------------------------
        # SOURCE_NAME
        # ----------------------------------------------------

        if [[ -z "${source_name}" ]]; then
            echo "[FEHLER] ${job_id}: SOURCE_NAME fehlt"
            errors=$((errors + 1))
        fi

        # ----------------------------------------------------
        # SOURCE_PATH
        # ----------------------------------------------------

        if [[ -z "${source_path}" ]]; then
            echo "[WARN]   ${job_id}: SOURCE_PATH fehlt"
            warnings=$((warnings + 1))
        fi

        # ----------------------------------------------------
        # Statusabhängige Prüfungen
        # ----------------------------------------------------

        case "${status}" in

            COMPLETE)

                if [[ -z "${paperless_document_id}" ]]; then
                    echo "[WARN]   ${job_id}: COMPLETE ohne Paperless-ID"
                    warnings=$((warnings + 1))
                fi

                if [[ -z "${archive_target}" ]]; then
                    echo "[WARN]   ${job_id}: COMPLETE ohne ARCHIVE_TARGET"
                    warnings=$((warnings + 1))
                fi

                ;;

            DUPLICATE)

                if [[ -z "$(get_job_value "${job_file}" "PAPERLESS_DUPLICATE_OF")" ]]; then
                    echo "[WARN]   ${job_id}: DUPLICATE ohne PAPERLESS_DUPLICATE_OF"
                    warnings=$((warnings + 1))
                fi

                ;;

            PAPERLESS_FAILED|ARCHIVE_FAILED)

                if [[ -z "$(get_job_value "${job_file}" "ERROR_TYPE")" ]]; then
                    echo "[WARN]   ${job_id}: Fehlerstatus ohne ERROR_TYPE"
                    warnings=$((warnings + 1))
                fi

                if [[ -z "$(get_job_value "${job_file}" "ERROR_MESSAGE")" ]]; then
                    echo "[WARN]   ${job_id}: Fehlerstatus ohne ERROR_MESSAGE"
                    warnings=$((warnings + 1))
                fi

                ;;

            PAPERLESS_PROCESSING|PAPERLESS_SUBMITTED)

                echo "[HINWEIS] ${job_id}: Status ${status}"

                ;;

            "")

                echo "[FEHLER] ${job_id}: STATUS fehlt"
                errors=$((errors + 1))
                ;;

        esac
    done

    if (( total == 0 )); then
        echo "[HINWEIS] Keine Jobs vorhanden."
    fi

    echo
    echo "------------------------------------------------------------"
    echo "Geprüfte Jobs: ${total}"
    echo "Fehler:        ${errors}"
    echo "Warnungen:     ${warnings}"
    echo "------------------------------------------------------------"
    echo
}


# ============================================================
# Diagnose-Menü
# ============================================================

diagnostic_menu() {
    while true; do
        clear

        echo "============================================================"
        echo " Diagnose"
        echo "============================================================"
        echo
        echo "  1) Statistik"
        echo "  2) System- und Konfigurationsprüfung"
        echo "  3) Job-Integritätsprüfung"
        echo "  4) Alles prüfen"
        echo "  5) Zurück"
        echo

        read -r -p "Auswahl [1-5]: " choice

        case "${choice}" in

            1)
                show_statistics
                read -r -p "Weiter mit Enter..."
                ;;

            2)
                system_check
                read -r -p "Weiter mit Enter..."
                ;;

            3)
                check_job_integrity
                read -r -p "Weiter mit Enter..."
                ;;

            4)
                show_statistics
                system_check
                check_job_integrity
                read -r -p "Weiter mit Enter..."
                ;;

            5)
                return
                ;;

            *)
                echo
                echo "Ungültige Auswahl."
                sleep 1
                ;;
        esac
    done
}


# ============================================================
# Status-Auswahl
# ============================================================

status_menu() {
    while true; do
        clear

        echo "============================================================"
        echo " Dokumentenverarbeitung nach Status"
        echo "============================================================"
        echo
        echo "  1) DUPLICATE"
        echo "  2) PAPERLESS_FAILED"
        echo "  3) ARCHIVE_FAILED"
        echo "  4) COMPLETE"
        echo "  5) PAPERLESS_PROCESSING"
        echo "  6) Alle Status"
        echo "  7) Zurück"
        echo

        read -r -p "Auswahl [1-7]: " choice

        case "${choice}" in
            1)
                show_jobs_by_status "DUPLICATE"
                read -r -p "Weiter mit Enter..."
                ;;

            2)
                show_jobs_by_status "PAPERLESS_FAILED"
                read -r -p "Weiter mit Enter..."
                ;;

            3)
                show_jobs_by_status "ARCHIVE_FAILED"
                read -r -p "Weiter mit Enter..."
                ;;

            4)
                show_jobs_by_status "COMPLETE"
                read -r -p "Weiter mit Enter..."
                ;;

            5)
                show_jobs_by_status "PAPERLESS_PROCESSING"
                read -r -p "Weiter mit Enter..."
                ;;

            6)
                show_jobs_by_status "ALL"
                read -r -p "Weiter mit Enter..."
                ;;

            7)
                return
                ;;

            *)
                echo
                echo "Ungültige Auswahl."
                sleep 1
                ;;
        esac
    done
}


# ============================================================
# Aufräumen
# ============================================================

cleanup() {
    echo
    echo "============================================================"
    echo " AUFRÄUMEN"
    echo "============================================================"
    echo
    echo "Folgende Workflow-Daten werden gelöscht:"
    echo "  - state/jobs/*"
    echo "  - scanpool/*"
    echo "  - state/active_job"
    echo
    echo "NICHT angefasst werden:"
    echo "  - gdrive:SCAN"
    echo "  - gdrive:PAPERLESS"
    echo "  - Paperless-Dokumente"
    echo

    read -r -p "Wirklich aufräumen? [j/N] " answer

    case "${answer}" in
        j|J|ja|JA|Ja)
            echo
            echo "Lösche Jobs..."
            rm -rf -- "${JOB_DIR:?}/"*

            echo "Leere Scanpool..."
            find "${SCANPOOL_DIR}" \
                -mindepth 1 \
                -maxdepth 1 \
                -type f \
                -delete

            echo "Entferne active_job..."
            rm -f -- "${ACTIVE_JOB_FILE}"

            echo
            echo "Aufräumen abgeschlossen."
            echo
            ;;

        *)
            echo
            echo "Abgebrochen."
            echo
            ;;
    esac
}


# ============================================================
# Hauptmenü
# ============================================================

while true; do
    clear

    echo "============================================================"
    echo " Paperless-Google-Drive Wartung"
    echo "============================================================"
    echo
    echo "  1) Jobs und Status anzeigen"
    echo "  2) Dokumentenverarbeitung nach Status"
    echo "  3) Diagnose"
    echo "  4) Aufräumen"
    echo "  x) Exit"
    echo

    read -r -p "Auswahl [1-4]: " choice

    case "${choice}" in

        1)
            show_jobs
            read -r -p "Weiter mit Enter..."
            ;;

        2)
            status_menu
            ;;

        3)
            diagnostic_menu
            ;;

        4)
            cleanup
            read -r -p "Weiter mit Enter..."
            ;;

        x|X)
            echo "Exit."
            exit 0
            ;;

        *)
            echo
            echo "Ungültige Auswahl."
            sleep 1
            ;;
    esac
done
