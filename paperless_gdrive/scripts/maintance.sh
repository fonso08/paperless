!/bin/bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/jobs.sh"
source "${SCRIPT_DIR}/lib/paperless_api.sh"

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

    # Bash-printf-%q-Escaping rückgängig machen
    value="${value//\\ / }"
    value="${value//\\,/,}"
    value="${value//\\\(/(}"
    value="${value//\\\)/)}"
    value="${value//\\\[/[}"
    value="${value//\\\]/]}"
    value="${value//\\\&/&}"

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
# Wiederanlauf verwaister Paperless-Jobs
# ============================================================

restart_stuck_jobs() {
    echo
    echo "============================================================"
    echo " Wiederanlauf"
    echo "============================================================"

    local job_file job_id status task_uuid task_json
    local task_status document_id source_file answer
    local celery_active

    for job_file in "${JOB_DIR}"/*/job.conf; do
        [[ -f "${job_file}" ]] || continue

        status="$(get_job_value "${job_file}" "STATUS")"
        [[ "${status}" == "PAPERLESS_PROCESSING" ]] || continue

        job_id="$(basename "$(dirname "${job_file}")")"
        task_uuid="$(get_job_value "${job_file}" "PAPERLESS_TASK_ID")"
        source_file="$(get_job_value "${job_file}" "SOURCE_FILE")"

        echo
        echo "Job:       ${job_id}"
        echo "Datei:     $(get_job_value "${job_file}" "SOURCE_NAME")"
        echo "Task:      ${task_uuid:-unbekannt}"

        if [[ -z "${task_uuid}" || ! -f "${source_file}" ]]; then
            echo "Übersprungen: Task-ID oder Quelldatei fehlt."
            continue
        fi

        if ! task_json="$(paperless_task_json "${task_uuid}")"; then
            echo "Übersprungen: Paperless-Task nicht abrufbar."
            continue
        fi

        task_status="$(printf '%s\n' "${task_json}" | jq -r '.status // "unbekannt"')"
        document_id="$(printf '%s\n' "${task_json}" | jq -r '.related_document_ids[0] // empty')"

        echo "Task-Status: ${task_status}"
        echo "Dokument-ID: ${document_id:-keine}"

        if [[ -n "${document_id}" ]]; then
            echo "Übersprungen: Paperless hat bereits ein Dokument zugeordnet."
            continue
        fi

        # Nicht neu einreichen, wenn der Task noch aktiv bearbeitet wird.
        if ! celery_active="$(docker exec paperless celery -A paperless inspect active --timeout=5 2>&1)"; then
            echo "Übersprungen: Aktive Celery-Tasks konnten nicht geprüft werden."
            continue
        fi

        if printf '%s\n' "${celery_active}" | grep -Fq "${task_uuid}"; then
            echo "Übersprungen: Task ist noch aktiv."
            continue
        fi

        if [[ "${task_status}" != "started" ]]; then
            echo "Übersprungen: Task-Status ist nicht 'started'."
            continue
        fi

        echo
        echo "Der Task scheint verwaist zu sein."
        read -r -p "Job auf COPIED_TO_POOL zurücksetzen? [j/N] " answer

        case "${answer}" in
            j|J|ja|JA|Ja)
                if job_set_status "${job_id}" "COPIED_TO_POOL"; then
                    echo "Job zurückgesetzt."
                    echo "Die erneute Übergabe erfolgt über den regulären Workflow."
                else
                    echo "FEHLER: Status konnte nicht geändert werden."
                fi
                ;;
            *)
                echo "Unverändert übersprungen."
                ;;
        esac
    done

    echo
    read -r -p "Weiter mit Enter..."
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
# Gemini-Fehlerjobs zurücksetzen
# ============================================================

reset_gemini_jobs() {
    echo
    echo "============================================================"
    echo " Reset Gemini"
    echo "============================================================"
    echo "Es werden ausschließlich Jobs mit STATUS=GEMINI_FAILED berücksichtigt."
    echo "Diese werden auf GEMINI_PENDING gesetzt und GEMINI_ATTEMPTS wird auf 0 gesetzt."
    echo "ERROR_TYPE und ERROR_MESSAGE bleiben als Fehlerhistorie erhalten."
    echo

    local job_file job_id status source_name attempts
    local count=0
    local changed=0
    local answer

    # Zuerst nur anzeigen und zählen; bis zur Bestätigung keine Änderungen.
    for job_file in "${JOB_DIR}"/*/job.conf; do
        [[ -f "${job_file}" ]] || continue
        status="$(get_job_value "${job_file}" "STATUS")"
        [[ "${status}" == "GEMINI_FAILED" ]] || continue

        job_id="$(basename "$(dirname "${job_file}")")"
        source_name="$(get_job_value "${job_file}" "SOURCE_NAME")"
        attempts="$(get_job_value "${job_file}" "GEMINI_ATTEMPTS")"
        printf '  %-36s Versuche: %-5s %s\n' \
            "${job_id}" "${attempts:-0}" "${source_name}"
        count=$((count + 1))
    done

    if (( count == 0 )); then
        echo "Keine Jobs mit STATUS=GEMINI_FAILED gefunden."
        echo
        return 0
    fi

    echo
    echo "Gefundene Jobs: ${count}"
    echo "Die erneute Verarbeitung erfolgt anschließend über Script 03."
    echo
    read -r -p "Alle aufgeführten Gemini-Fehlerjobs zurücksetzen? [j/N] " answer

    case "${answer}" in
        j|J|ja|JA|Ja) ;;
        *)
            echo "Abgebrochen. Keine Änderungen."
            return 0
            ;;
    esac

    for job_file in "${JOB_DIR}"/*/job.conf; do
        [[ -f "${job_file}" ]] || continue

        # Status erneut prüfen, damit nur weiterhin fehlgeschlagene Jobs geändert werden.
        status="$(get_job_value "${job_file}" "STATUS")"
        [[ "${status}" == "GEMINI_FAILED" ]] || continue

        job_id="$(basename "$(dirname "${job_file}")")"

        # Erst Zähler zurücksetzen, dann den Job wieder freigeben.
        if ! job_update "${job_id}" "GEMINI_ATTEMPTS" "0"; then
            echo "[FEHLER] ${job_id}: GEMINI_ATTEMPTS konnte nicht zurückgesetzt werden."
            continue
        fi

        if ! job_set_status "${job_id}" "GEMINI_PENDING"; then
            echo "[FEHLER] ${job_id}: Status konnte nicht auf GEMINI_PENDING gesetzt werden."
            continue
        fi

        echo "[OK] ${job_id}: GEMINI_FAILED -> GEMINI_PENDING (Versuche=0)"
        changed=$((changed + 1))
    done

    echo
    echo "Zurückgesetzte Jobs: ${changed} von ${count}"
    echo "Fehlerdetails wurden zur Diagnose beibehalten."
    echo
}

# ============================================================
# Proposals verwalten
# ============================================================

PROPOSAL_DIR="${PROPOSAL_DIR:-/media/BlueDisc3/PAPERLESS/state/metadata/proposals}"

# Prüft das Proposal-Verzeichnis und sucht ein Proposal anhand
# der Dokument-ID oder des Dateinamens.
find_proposal_file() {
    local wanted="$1"
    local file
    local document_id

    [[ -d "${PROPOSAL_DIR}" ]] || return 1

    for file in "${PROPOSAL_DIR}"/*.json; do
        [[ -f "${file}" ]] || continue

        if [[ "$(basename "${file}")" == "${wanted}" ||
              "$(basename "${file}" .json)" == "${wanted}" ]]; then
            printf '%s\n' "${file}"
            return 0
        fi

        document_id="$(jq -r '.document_id // empty' "${file}" 2>/dev/null)" ||
            continue

        if [[ "${document_id}" == "${wanted}" ]]; then
            printf '%s\n' "${file}"
            return 0
        fi
    done

    return 1
}


# ------------------------------------------------------------
# 6.1 Alle Proposals auflisten
# ------------------------------------------------------------

show_proposals() {
    local file
    local count=0

    echo
    echo "============================================================"
    echo " Proposals – Übersicht"
    echo "============================================================"

    if [[ ! -d "${PROPOSAL_DIR}" ]]; then
        echo "[FEHLER] Proposal-Verzeichnis nicht gefunden:"
        echo "         ${PROPOSAL_DIR}"
        echo
        return 1
    fi

    printf '%-8s %-9s %-24s %-24s %-12s %-8s %s\n' \
        "Dok-ID" "Applied" "Hauptkategorie" "Korrespondent" \
        "Datum" "Conf." "Titel"

    echo "------------------------------------------------------------------------------------------------"

    for file in "${PROPOSAL_DIR}"/*.json; do
        [[ -f "${file}" ]] || continue

        if ! jq -e 'type == "object"' "${file}" >/dev/null 2>&1; then
            printf '%-8s %-9s %s\n' "?" "FEHLER" "$(basename "${file}")"
            continue
        fi

        jq -r '
            [
                (.document_id // "?"),
                (if .applied == true then "ja" else "nein" end),
                (.proposal.primary_tag // .primary_tag // "-"),
                (.proposal.correspondent // .correspondent // "-"),
                (.proposal.document_date // .document_date // "-"),
                ((.proposal.confidence // .confidence // null)
                    | if . == null then "-" else tostring end),
                (.proposal.title // .title // "-")
            ]
            | map(tostring | gsub("[\t\r\n]"; " "))
            | @tsv
        ' "${file}" |
        while IFS=$'\t' read -r id applied category correspondent date confidence title; do
            printf '%-8s %-9s %-24.24s %-24.24s %-12s %-8s %s\n' \
                "${id}" "${applied}" "${category}" "${correspondent}" \
                "${date}" "${confidence}" "${title}"
        done

        count=$((count + 1))
    done

    echo
    echo "Proposal-Verzeichnis: ${PROPOSAL_DIR}"
    echo "Hinweis: Die Übersicht zeigt die wichtigsten Felder."
    echo
}


# ------------------------------------------------------------
# 6.2 Einzelnes Proposal anzeigen
# ------------------------------------------------------------

show_one_proposal() {
    local wanted
    local file

    read -r -p "Dokument-ID oder Proposal-Dateiname: " wanted

    if [[ -z "${wanted}" ]]; then
        echo "Keine Auswahl."
        return
    fi

    if ! file="$(find_proposal_file "${wanted}")"; then
        echo "[FEHLER] Kein Proposal für '${wanted}' gefunden."
        return
    fi

    echo
    echo "============================================================"
    echo " Proposal: $(basename "${file}")"
    echo "============================================================"

    if ! jq . "${file}"; then
        echo "[FEHLER] Proposal enthält kein gültiges JSON."
    fi

    echo
}


# ------------------------------------------------------------
# 6.3 Applied-Status zurücksetzen
# ------------------------------------------------------------

reset_proposal_applied() {
    local wanted
    local file
    local answer
    local temp_file
    local backup_file

    read -r -p "Dokument-ID oder Proposal-Dateiname: " wanted

    if [[ -z "${wanted}" ]]; then
        echo "Keine Auswahl."
        return
    fi

    if ! file="$(find_proposal_file "${wanted}")"; then
        echo "[FEHLER] Kein Proposal für '${wanted}' gefunden."
        return
    fi

    if ! jq -e 'type == "object"' "${file}" >/dev/null 2>&1; then
        echo "[FEHLER] Ungültiges Proposal-JSON: ${file}"
        return
    fi

    echo
    echo "Ausgewähltes Proposal: ${file}"
    jq '{
        document_id,
        title: (.proposal.title // .title // null),
        applied: (.applied // false),
        applied_at: (.applied_at // null)
    }' "${file}"

    if [[ "$(jq -r '.applied // false' "${file}")" != "true" ]]; then
        echo
        echo "Hinweis: Das Proposal ist bereits nicht als applied markiert."
        echo "Es wird nichts geändert."
        return
    fi

    echo
    echo "Es werden nur diese Felder geändert:"
    echo "  applied    = false"
    echo "  applied_at = null"
    echo
    echo "Das Paperless-Dokument wird NICHT geändert."
    echo "Das Proposal wird NICHT automatisch erneut angewendet."
    echo

    read -r -p "Applied-Status wirklich zurücksetzen? [j/N] " answer

    case "${answer}" in
        j|J|ja|JA|Ja) ;;
        *)
            echo "Abgebrochen. Keine Änderung."
            return
            ;;
    esac

    # Sicherung vor jeder Änderung
    backup_file="${file}.bak.$(date +%Y%m%d_%H%M%S)"

    if ! cp -p -- "${file}" "${backup_file}"; then
        echo "[FEHLER] Backup konnte nicht erstellt werden."
        return 1
    fi

    temp_file="$(mktemp "${file}.tmp.XXXXXX")" || {
        echo "[FEHLER] Temporäre Datei konnte nicht erstellt werden."
        return 1
    }

    if ! jq '
        .applied = false
        | .applied_at = null
    ' "${file}" > "${temp_file}"; then
        rm -f -- "${temp_file}"
        echo "[FEHLER] Proposal konnte nicht bearbeitet werden."
        echo "Originaldatei bleibt unverändert."
        return 1
    fi

    # Ergebnis validieren, bevor das Original ersetzt wird
    if ! jq -e '
        type == "object"
        and .applied == false
        and .applied_at == null
    ' "${temp_file}" >/dev/null; then
        rm -f -- "${temp_file}"
        echo "[FEHLER] Validierung fehlgeschlagen."
        echo "Originaldatei bleibt unverändert."
        return 1
    fi

    chmod --reference="${file}" "${temp_file}" 2>/dev/null || true

    if ! mv -- "${temp_file}" "${file}"; then
        rm -f -- "${temp_file}"
        echo "[FEHLER] Proposal-Datei konnte nicht ersetzt werden."
        echo "Backup: ${backup_file}"
        return 1
    fi

    echo
    echo "[OK] Applied-Status zurückgesetzt."
    echo "Backup: ${backup_file}"
    echo
}


# ------------------------------------------------------------
# Proposals-Untermenü
# ------------------------------------------------------------

proposals_menu() {
    local choice

    while true; do
        clear

        echo "============================================================"
        echo " Proposals"
        echo "============================================================"
        echo
        echo "  1) Alle Proposals auflisten"
        echo "  2) Einzelnes Proposal anzeigen"
        echo "  3) Applied-Status zurücksetzen"
        echo "  4) Zurück"
        echo

        read -r -p "Auswahl [1-4]: " choice

        case "${choice}" in
            1)
                show_proposals
                read -r -p "Weiter mit Enter..."
                ;;
            2)
                show_one_proposal
                read -r -p "Weiter mit Enter..."
                ;;
            3)
                reset_proposal_applied
                read -r -p "Weiter mit Enter..."
                ;;
            4)
                return
                ;;
            *)
                echo "Ungültige Auswahl."
                sleep 1
                ;;
        esac
    done
}


# ============================================================
# Hauptmenü
# ============================================================

while true; do
    clear

    echo "============================================================"
    echo " Paperless Wartung"
    echo "============================================================"
    echo
    echo "  1) Jobs und Status anzeigen"
    echo "  2) Dokumentenverarbeitung nach Status"
    echo "  3) Diagnose"
    echo "  4) Aufräumen"
    echo "  5) Wiederanlauf"
    echo "  6) Proposals"
    echo "  7) Reset Gemini (GEMINI_FAILED zurücksetzen)"
    echo "  x) Exit"
    echo

    read -r -p "Auswahl [1-7/x]: " choice

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
        5)
            restart_stuck_jobs
            ;;
        6)
            proposals_menu
            ;;
        7)
            reset_gemini_jobs
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
