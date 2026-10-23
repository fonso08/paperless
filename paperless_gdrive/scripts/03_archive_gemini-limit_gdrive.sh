#!/bin/bash
# ============================================================
#
# Ablauf:
#   - Paperless Task-Status überwachen
#   - success -> Dokument-ID übernehmen
#   - Kategorie anhand der Paperless-Tags ermitteln
#   - erster passender gdrive_* Tag gewinnt
#   - kein passender Tag -> unsortiert
#   - Archivdateiname ermitteln
#   - Archivziel ermitteln
#   - Datei nach Google Drive archivieren
#   - Upload über Dateigröße verifizieren
#   - Google-Drive-Quelle erst nach erfolgreicher
#     Archivverifikation löschen
#   - Google-Drive-Löschung verifizieren
#   - lokale Quelle erst danach löschen
#   - endgültig COMPLETE setzen
#
#   - duplicate:
#       * Duplikat erkennen
#       * Original-Dokument-ID speichern
#       * Google-Drive-Quelle löschen
#       * Google-Drive-Löschung verifizieren
#       * lokale Quelle löschen
#       * DUPLICATE beibehalten
#
#   - echter failure -> PAPERLESS_FAILED
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/jobs.sh"
source "${SCRIPT_DIR}/lib/paperless_api.sh"

init_directories
check_common_requirements
acquire_script_lock

info "=== Start Script 03 ==="

if [[ -z "${PAPERLESS_TOKEN:-}" ]]; then
    error "PAPERLESS_TOKEN ist nicht gesetzt."
    exit 1
fi


# ============================================================
# Kategorie anhand der Paperless-Tags ermitteln
#
# Regel:
#   erster passender gdrive_* Tag gewinnt
#   kein passender Tag -> PAPERLESS_DEFAULT_CATEGORY
# ============================================================

# Neue Dokumente: Gemini vor Archivierung, mit sicherer Quarantaene.
METADATA_ROOT="${METADATA_ROOT:-/home/pi/docker/paperless/paperless_metadata}"
METADATA_STATE="${STATE_DIR}/metadata"

metadata_safe_name() {
    local v="$1"
    v="${v//$'\n'/ }"; v="${v//$'\r'/ }"
    v="${v//\//-}"; v="${v//\\/-}"; v="${v//:/-}"
    v="${v//\*/-}"; v="${v//\?/-}"; v="${v//\"/-}"
    v="${v//</-}"; v="${v//>/-}"; v="${v//|/-}"
    v="${v// /_}"
    printf '%s' "$v" | sed -E 's/_+/_/g; s/^[_. -]+//; s/[_. -]+$//'
}

# Exakter Segmenttest: noLLM gilt nur fuer einen eigenen Pfadbestandteil.
nollm_source_path() {
    local path="${1:-}"
    case "/${path#/}/" in
        */noLLM/*) return 0 ;;
        *) return 1 ;;
    esac
}

# noLLM-Dokumente bekommen das Paperless-Tag, laufen aber nicht durch Gemini.
nollm_tag_document() {
    local did="$1" tags tag_id doc_json current_tags merged payload response
    tags="$(paperless_curl "$(paperless_api_url 'tags/?page_size=1000')")" || return 1
    tag_id="$(jq -r '[.results[]? | select(.name == "noLLM")][0].id // empty' <<< "$tags")"
    if [[ -z "$tag_id" ]]; then
        response="$(curl -fsS --connect-timeout 10 --max-time 30 \
            -H "Authorization: Token ${PAPERLESS_TOKEN}" \
            -H 'Accept: application/json' -H 'Content-Type: application/json' \
            -X POST "$(paperless_api_url 'tags/')" \
            --data '{"name":"noLLM"}')" || return 1
        tag_id="$(jq -r '.id // empty' <<< "$response")"
    fi
    [[ "$tag_id" =~ ^[0-9]+$ ]] || { error 'Paperless-Tag noLLM konnte nicht ermittelt/angelegt werden.'; return 1; }
    doc_json="$(paperless_document_json "$did")" || return 1
    current_tags="$(jq -c '.tags // []' <<< "$doc_json")" || return 1
    merged="$(jq -cn --argjson old "$current_tags" --argjson add "$tag_id" '($old + [$add] | unique)')" || return 1
    payload="$(jq -cn --argjson tags "$merged" '{tags:$tags}')" || return 1
    curl -fsS --connect-timeout 10 --max-time 30 \
        -H "Authorization: Token ${PAPERLESS_TOKEN}" \
        -H 'Accept: application/json' -H 'Content-Type: application/json' \
        -X PATCH "$(paperless_api_url "documents/${did}/")" \
        --data "$payload" >/dev/null || return 1
    info "Paperless-Tag noLLM fuer Dokument ${did} gesetzt."
}

metadata_process_job() {
    local jid="$1" did="$2"
    local proposal="$METADATA_STATE/proposals/${did}.json"
    local doc category corr_id corr_name date title ext stem filename target
    if [[ ! -f "$proposal" ]]; then
        info "Gemini analysiert Dokument $did"
        if ! "$METADATA_ROOT/scripts/01_analyze.sh" --id "$did"; then
            job_update "$jid" ERROR_TYPE GEMINI_ANALYSIS_FAILED
            job_set_status "$jid" GEMINI_FAILED
            return 1
        fi
    fi
    if [[ ! -f "$proposal" ]] || ! jq -e '.proposal | type=="object"' "$proposal" >/dev/null; then
        job_update "$jid" ERROR_TYPE GEMINI_PROPOSAL_MISSING
        job_set_status "$jid" GEMINI_FAILED
        return 1
    fi
    # Sicherheitsregel: Kein Dokument wird allein aufgrund eines Gemini-Ergebnisses
    # archiviert. Erforderlich ist eine explizite Freigabe aus quarantine_web.
    # Die Weboberflaeche setzt manual_review.approved_at und REVIEW_APPROVED.
    if ! jq -e '(.manual_review.approved_at // "") | length > 0' "$proposal" >/dev/null; then
        job_set_status "$jid" QUARANTINE
        info "Dokument $did wartet auf ausdrueckliche Freigabe in der Quarantaene"
        return 0
    fi
    if ! jq -e '(.proposal.requires_review == false) and
        (.proposal.review_decision == "no_check_needed") and
        ((.proposal.validation_warnings // []) | length == 0) and
        ((.proposal.primary_tag // "") | length > 0)' "$proposal" >/dev/null; then
        job_set_status "$jid" QUARANTINE
        info "Dokument $did: Freigabe-/Validierungsdaten unvollstaendig; bleibt in Quarantaene"
        return 0
    fi
    if ! jq -e '.applied == true' "$proposal" >/dev/null; then
        if ! "$METADATA_ROOT/scripts/03_apply_proposals.sh" --id "$did" --apply; then
            job_update "$jid" ERROR_TYPE GEMINI_APPLY_FAILED
            job_set_status "$jid" GEMINI_FAILED
            return 1
        fi
    fi
    if ! jq -e '.applied == true' "$proposal" >/dev/null; then
        job_update "$jid" ERROR_TYPE GEMINI_APPLY_UNCONFIRMED
        job_set_status "$jid" GEMINI_FAILED
        return 1
    fi
    doc="$(paperless_document_json "$did")" || return 1
    category="$(jq -r '.proposal.primary_tag' "$proposal")"
    corr_id="$(jq -r '.correspondent // empty' <<< "$doc")"
    corr_name="SONSTIGES"
    if [[ -n "$corr_id" ]]; then
        corr_name="$(paperless_curl "$(paperless_api_url "correspondents/${corr_id}/")" | jq -r '.name // empty')" || return 1
        [[ -n "$corr_name" ]] || return 1
    fi
    # Fuer den Dateinamen ausschliesslich das gepruefte Dokumentdatum verwenden.
    # Ein vorhandenes Paperless-created-Datum kann das Import-/Scan-Datum sein.
    date="$(jq -r '.proposal.document_date // empty' "$proposal")"
    title="$(jq -r '.title // empty' <<< "$doc")"
    ext="${SOURCE_NAME##*.}"; ext="${ext,,}"
    case "$ext" in pdf|jpg|jpeg|png) ;; *) error "Format nicht erlaubt: $ext"; return 1 ;; esac
    category="$(metadata_safe_name "$category")"
    corr_name="$(metadata_safe_name "$corr_name")"
    title="$(metadata_safe_name "$title")"
    [[ -n "$category" && -n "$corr_name" ]] || return 1
    if [[ "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        stem="${date//-/}_${category}_${corr_name}_${title}"
    else
        stem="${category}_${corr_name}_${title}"
    fi
    # ID im Namen sorgt auch nach Trunkierung fuer stabile Eindeutigkeit.
    local suffix="_ID-${did}" max=$((80 - ${#ext} - 1 - ${#did} - 4))
    (( max > 0 )) || return 1
    filename="${stem:0:max}${suffix}.${ext}"
    target="${GDRIVE_ARCHIVE%/}/${category}/${corr_name}"
    job_update "$jid" CATEGORY "$category"
    job_update "$jid" ARCHIVE_FILE "$filename"
    job_update "$jid" ARCHIVE_TARGET "$target"
    job_set_status "$jid" PAPERLESS_DONE
    info "Gemini bestaetigt: $jid -> $target/$filename"
}

paperless_category_from_document() {
    local document_id="$1"
    local tags_json
    local tag
    local category

    tags_json="$(
        paperless_document_tags_json "${document_id}"
    )"

    while IFS= read -r tag; do
        [[ -n "${tag}" ]] || continue

        case "${tag}" in

            gdrive_haus)
                category="${PAPERLESS_TAG__gdrive_haus}"
                ;;

            gdrive_aerzte)
                category="${PAPERLESS_TAG__gdrive_aerzte}"
                ;;

            gdrive_versicherungen)
                category="${PAPERLESS_TAG__gdrive_versicherungen}"
                ;;

            gdrive_finanzen)
                category="${PAPERLESS_TAG__gdrive_finanzen}"
                ;;

            gdrive_vertraege)
                category="${PAPERLESS_TAG__gdrive_vertraege}"
                ;;

            *)
                continue
                ;;

        esac

        printf '%s\n' "${category}"
        return 0

    done < <(
        jq -r '
            .[] |
            if type == "object"
            then .name // empty
            else .
            end
        ' <<< "${tags_json}"
    )

    printf '%s\n' "${PAPERLESS_DEFAULT_CATEGORY}"
}


# ============================================================
# Archivdateiname ermitteln
# ============================================================

archive_filename_from_job() {
    local source_name="$1"
    local job_id="$2"

    local stem
    local extension

    stem="${source_name%.*}"
    extension="${source_name##*.}"

    if [[ "${source_name}" == "${stem}" ]]; then
        extension=""
    fi

    if [[ "${ARCHIVE_ADD_JOB_ID}" == "true" ]]; then

        if [[ -n "${extension}" ]]; then
            printf '%s-%s.%s\n' \
                "${stem}" \
                "${job_id}" \
                "${extension}"
        else
            printf '%s-%s\n' \
                "${stem}" \
                "${job_id}"
        fi

    else
        printf '%s\n' "${source_name}"
    fi
}


# ============================================================
# Archivziel anhand der Kategorie ermitteln
# ============================================================

archive_target_from_category() {
    local category="$1"

    printf '%s/%s\n' \
        "${GDRIVE_ARCHIVE%/}" \
        "${category}"
}


# ============================================================
# Upload nach Google Drive und Größenprüfung
#
# Rückgabe:
#   0 = erfolgreich verifiziert
#   1 = Fehler
# ============================================================

archive_upload_and_verify() {
    local source_file="$1"
    local archive_target="$2"
    local archive_file="$3"

    local destination
    local local_size
    local remote_size

    if [[ ! -f "${source_file}" ]]; then
        error "Lokale Quelldatei existiert nicht: ${source_file}"
        return 1
    fi

    local_size="$(
        stat -c '%s' "${source_file}"
    )"

    destination="${archive_target%/}/${archive_file}"

    info "Archiv-Upload:"
    info "Quelle: ${source_file}"
    info "Ziel: ${destination}"
    info "Lokale Größe: ${local_size} Bytes"

    if ! rclone copyto \
        "${source_file}" \
        "${destination}"
    then
        error "rclone Upload fehlgeschlagen."
        return 1
    fi

    remote_size="$(
        rclone size \
            "${destination}" \
            --json \
        | jq -r '.bytes // 0'
    )"

    info "Remote-Größe: ${remote_size} Bytes"

    if [[ "${remote_size}" != "${local_size}" ]]; then
        error "Archiv-Verifikation fehlgeschlagen."
        error "Lokale Größe: ${local_size}"
        error "Remote Größe: ${remote_size}"
        return 1
    fi

    info "Archiv erfolgreich hochgeladen und verifiziert."

    return 0
}


# ============================================================
# Google-Drive-Quelle sicher löschen und verifizieren
#
# Rückgabe:
#   0 = Quelle ist nachweislich nicht mehr vorhanden
#   1 = Fehler
#
# Verhalten:
#   - Datei vorhanden -> löschen -> Löschung verifizieren
#   - Datei bereits nicht vorhanden -> ebenfalls erfolgreich
#   - rclone-Abfrage selbst fehlerhaft -> Fehler
# ============================================================

delete_gdrive_source_and_verify() {
    local remote_source="$1"
    local remote_dir
    local remote_file
    local remote_listing

    remote_dir="${remote_source%/*}"
    remote_file="${remote_source##*/}"

    info "Prüfe Google-Drive-Quelle: ${remote_source}"

    # --------------------------------------------------------
    # Quelle über das übergeordnete Verzeichnis prüfen.
    #
    # Wichtig:
    # rclone lsf auf einen exakten, nicht mehr vorhandenen
    # Dateipfad liefert beim Google-Drive-Backend RC=3
    # ("directory not found"). Das ist hier kein Fehler,
    # sondern bedeutet: Datei ist bereits weg.
    # --------------------------------------------------------

    if ! remote_listing="$(
        rclone lsf \
            --files-only \
            "${remote_dir}" \
            2>/dev/null
    )"; then

        error "Google-Drive-Verzeichnis konnte nicht geprüft werden."
        error "Verzeichnis: ${remote_dir}"
        return 1
    fi

    if printf '%s\n' "${remote_listing}" | grep -Fqx -- "${remote_file}"; then

        info "Google-Drive-Quelle vorhanden."
        info "Lösche: ${remote_source}"

        if ! rclone deletefile "${remote_source}"; then
            error "Google-Drive-Quelle konnte nicht gelöscht werden."
            error "Quelle: ${remote_source}"
            return 1
        fi

        info "Google-Drive-Quelle gelöscht."

    else

        info "Google-Drive-Quelle ist bereits nicht vorhanden."

    fi


    # --------------------------------------------------------
    # Löschung über das übergeordnete Verzeichnis verifizieren
    # --------------------------------------------------------

    if ! remote_listing="$(
        rclone lsf \
            --files-only \
            "${remote_dir}" \
            2>/dev/null
    )"; then

        error "Google-Drive-Löschung konnte nicht verifiziert werden."
        error "Verzeichnis: ${remote_dir}"
        return 1
    fi

    if printf '%s\n' "${remote_listing}" | grep -Fqx -- "${remote_file}"; then

        error "Google-Drive-Quelle ist weiterhin vorhanden."
        error "Quelle: ${remote_source}"
        return 1

    fi

    info "Google-Drive-Löschung erfolgreich verifiziert."

    return 0
}


# ============================================================
# Lokale Quelle sicher löschen
#
# Rückgabe:
#   0 = Datei nicht vorhanden oder erfolgreich gelöscht
#   1 = Löschung fehlgeschlagen
# ============================================================

delete_local_source() {
    local source_file="$1"

    if [[ ! -e "${source_file}" ]]; then
        info "Lokale Quelle ist bereits nicht vorhanden."
        return 0
    fi

    info "Lösche lokale Quelle: ${source_file}"

    if ! rm -f -- "${source_file}"; then
        error "Lokale Quelle konnte nicht gelöscht werden."
        error "Datei: ${source_file}"
        return 1
    fi

    if [[ -e "${source_file}" ]]; then
        error "Lokale Quelle ist nach dem Löschen weiterhin vorhanden."
        error "Datei: ${source_file}"
        return 1
    fi

    info "Lokale Quelle erfolgreich gelöscht."

    return 0
}


# ============================================================
# DUPLICATE vollständig bereinigen
#
# Reihenfolge:
#   1. Google-Drive-Quelle löschen
#   2. Google-Drive-Löschung verifizieren
#   3. GDRIVE_SOURCE_DELETED=true
#   4. lokale Quelle löschen
#   5. LOCAL_SOURCE_DELETED=true
#   6. Status DUPLICATE beibehalten
# ============================================================

cleanup_duplicate() {
    local job_id="$1"

    local source_file="${SOURCE_FILE:-}"
    local source_path="${SOURCE_PATH:-}"

    local gdrive_source_deleted="${GDRIVE_SOURCE_DELETED:-false}"
    local local_source_deleted="${LOCAL_SOURCE_DELETED:-false}"

    if [[ -z "${source_path}" ]]; then

        error "Job ${job_id}: SOURCE_PATH ist leer."

        job_update \
            "${job_id}" \
            "ERROR_TYPE" \
            "DUPLICATE_SOURCE_PATH_MISSING"

        job_update \
            "${job_id}" \
            "ERROR_MESSAGE" \
            "SOURCE_PATH fehlt für das Duplikat."

        return 1
    fi

    if [[ -z "${source_file}" ]]; then

        error "Job ${job_id}: SOURCE_FILE ist leer."

        job_update \
            "${job_id}" \
            "ERROR_TYPE" \
            "DUPLICATE_SOURCE_FILE_MISSING"

        job_update \
            "${job_id}" \
            "ERROR_MESSAGE" \
            "SOURCE_FILE fehlt für das Duplikat."

        return 1
    fi


    # --------------------------------------------------------
    # Google Drive
    # --------------------------------------------------------

    if [[ "${gdrive_source_deleted}" != "true" ]]; then

        remote_source="${GDRIVE_SCAN}/${source_path}"

        info "Duplikat: Google-Drive-Quelle:"
        info "${remote_source}"

        if ! delete_gdrive_source_and_verify \
            "${remote_source}"
        then

            error "Job ${job_id}: Duplikat konnte nicht aus Google Drive entfernt werden."

            job_update \
                "${job_id}" \
                "ERROR_TYPE" \
                "DUPLICATE_GDRIVE_DELETE_FAILED"

            job_update \
                "${job_id}" \
                "ERROR_MESSAGE" \
                "Duplikat konnte nicht sicher aus ${remote_source} entfernt werden."

            return 1
        fi

        job_update \
            "${job_id}" \
            "GDRIVE_SOURCE_DELETED" \
            "true"

    else

        info "Google-Drive-Quelle laut Job bereits gelöscht."

    fi


    # --------------------------------------------------------
    # Lokale Quelle
    # --------------------------------------------------------

    if [[ "${local_source_deleted}" != "true" ]]; then

        if ! delete_local_source "${source_file}"; then

            error "Job ${job_id}: lokale Duplikat-Datei konnte nicht entfernt werden."

            job_update \
                "${job_id}" \
                "ERROR_TYPE" \
                "DUPLICATE_LOCAL_DELETE_FAILED"

            job_update \
                "${job_id}" \
                "ERROR_MESSAGE" \
                "Lokale Duplikat-Datei konnte nicht sicher gelöscht werden."

            return 1
        fi

        job_update \
            "${job_id}" \
            "LOCAL_SOURCE_DELETED" \
            "true"

    else

        info "Lokale Quelle laut Job bereits gelöscht."

    fi

    # --------------------------------------------------------
    # Paperless-Aufmerksamkeit für Duplikat quittieren
    # --------------------------------------------------------

    if [[ -n "${PAPERLESS_TASK_ID:-}" ]]; then

        info "Quittiere Paperless-Task: ${PAPERLESS_TASK_ID}"

        if ! paperless_task_acknowledge "${PAPERLESS_TASK_ID}"; then

            error "Job ${job_id}: Paperless-Task konnte nicht quittiert werden."

            job_update \
                "${job_id}" \
                "ERROR_TYPE" \
                "DUPLICATE_TASK_ACKNOWLEDGE_FAILED"

            job_update \
                "${job_id}" \
                "ERROR_MESSAGE" \
                "Paperless-Task ${PAPERLESS_TASK_ID} konnte nicht quittiert werden."

            return 1
        fi

        info "Paperless-Task erfolgreich quittiert."

    else

        error "Job ${job_id}: PAPERLESS_TASK_ID ist leer."

        job_update \
            "${job_id}" \
            "ERROR_TYPE" \
            "DUPLICATE_TASK_ID_MISSING"

        job_update \
            "${job_id}" \
            "ERROR_MESSAGE" \
            "PAPERLESS_TASK_ID fehlt für das Duplikat."

        return 1

    fi

    # --------------------------------------------------------
    # Duplikat vollständig bereinigt
    # --------------------------------------------------------

    job_update \
        "${job_id}" \
        "COMPLETED_AT" \
        "$(iso_now)"

    job_update \
        "${job_id}" \
        "ERROR_TYPE" \
        ""

    job_update \
        "${job_id}" \
        "ERROR_MESSAGE" \
        ""

    job_set_status \
        "${job_id}" \
        "DUPLICATE"

    info "Job ${job_id}: Duplikat vollständig bereinigt."
    info "Status bleibt DUPLICATE."

    return 0
}


# Pro Scriptlauf höchstens diese Anzahl Jobs durch die Gemini-Metadatenverarbeitung
# schicken. Kann bei Bedarf über GEMINI_MAX_PER_RUN angepasst werden.
GEMINI_MAX_PER_RUN="${GEMINI_MAX_PER_RUN:-10}"
if [[ ! "${GEMINI_MAX_PER_RUN}" =~ ^[1-9][0-9]*$ ]]; then
    error "GEMINI_MAX_PER_RUN muss eine positive ganze Zahl sein (aktuell: ${GEMINI_MAX_PER_RUN})."
    exit 1
fi

gemini_processed=0
gemini_limit_logged=false
processed=0

while IFS= read -r job_file; do
    [[ -f "${job_file}" ]] || continue

    job_id="$(basename "$(dirname "${job_file}")")"

    # --------------------------------------------------------
    # Job vollständig laden.
    #
    # Wichtig:
    # job_update speichert Werte mit Bash printf %q.
    # job_load/source interpretiert diese Werte korrekt.
    # --------------------------------------------------------

    if ! job_load "${job_id}"; then
        error "Job ${job_id}: Laden der Jobdatei fehlgeschlagen."
        continue
    fi

    status="${STATUS:-}"

    case "${status}" in
        PAPERLESS_SUBMITTED|PAPERLESS_PROCESSING|GEMINI_PENDING|GEMINI_FAILED|GEMINI_SKIPPED|REVIEW_APPROVED|QUARANTINE|PAPERLESS_DONE|ARCHIVE_PROCESSING|ARCHIVE_FAILED|DUPLICATE)
            ;;
        *)
            continue
            ;;
    esac


    # ========================================================
    # Bereits erkanntes DUPLICATE bereinigen
    #
    # Dadurch werden auch alte DUPLICATE-Jobs verarbeitet,
    # die vor dieser Script-Version entstanden sind.
    # ========================================================

    if [[ "${status}" == "DUPLICATE" ]]; then

        info "Prüfe bereits erkanntes Duplikat: ${job_id}"

        if cleanup_duplicate "${job_id}"; then
            processed=$((processed + 1))
        else
            error "Job ${job_id}: Duplikat konnte nicht vollständig bereinigt werden."
        fi

        continue
    fi


    # noLLM wartet auf explizite Freigabe in der Quarantaene-Weboberflaeche.
    # Es darf niemals in den Gemini-Verarbeitungspfad fallen.
    if [[ "$status" == "GEMINI_SKIPPED" ]]; then
        continue
    fi

    # Quarantaene bleibt bis zur manuellen Freigabe unveraendert.
    if [[ "$status" == "QUARANTINE" ]]; then
        continue
    fi
    if [[ "$status" == "GEMINI_PENDING" || "$status" == "GEMINI_FAILED" || "$status" == "REVIEW_APPROVED" ]]; then
        # Nur diesen Verarbeitungspfad begrenzen. Andere Jobtypen (z. B.
        # bereits freigegebene Archivierungen und Duplikatbereinigung) laufen weiter.
        if (( gemini_processed >= GEMINI_MAX_PER_RUN )); then
            if [[ "$gemini_limit_logged" != true ]]; then
                info "Gemini-Limit erreicht (${GEMINI_MAX_PER_RUN} Jobs); weitere Gemini-Jobs bleiben für den nächsten Scriptlauf unverändert liegen."
                gemini_limit_logged=true
            fi
            continue
        fi

        attempts="${GEMINI_ATTEMPTS:-0}"
        [[ "$attempts" =~ ^[0-9]+$ ]] || attempts=0
        if [[ "$status" == "GEMINI_FAILED" && "$attempts" -ge 3 ]]; then
            warn "Job $job_id: drei Gemini-Fehlversuche; manuelle Fehlerbehebung erforderlich."
            continue
        fi
        document_id="${PAPERLESS_DOCUMENT_ID:-}"
        if [[ ! "$document_id" =~ ^[0-9]+$ ]]; then
            error "Job $job_id: Dokument-ID fehlt fuer Gemini"
            continue
        fi
        job_update "$job_id" GEMINI_ATTEMPTS "$((attempts + 1))"
        gemini_processed=$((gemini_processed + 1))
        info "Gemini-Verarbeitung in diesem Lauf: ${gemini_processed}/${GEMINI_MAX_PER_RUN} (Job ${job_id})"
        metadata_process_job "$job_id" "$document_id" || true
        processed=$((processed + 1))
        continue
    fi

    # ========================================================
    # PAPERLESS_DONE / ARCHIVE_PROCESSING / ARCHIVE_FAILED:
    # Archivierung durchführen; dafür ist keine Task-ID nötig.
    # ========================================================

    if [[ "${status}" == "PAPERLESS_DONE" || "${status}" == "ARCHIVE_PROCESSING" || "${status}" == "ARCHIVE_FAILED" ]]; then

        document_id="${PAPERLESS_DOCUMENT_ID:-}"

        if [[ -z "${document_id}" ]]; then
            error "Job ${job_id}: keine PAPERLESS_DOCUMENT_ID vorhanden."
            continue
        fi

        info "Archivierung für Job: ${job_id}"
        info "Paperless Dokument-ID: ${document_id}"


        # ----------------------------------------------------
        # Kategorie
        # ----------------------------------------------------

        category="${CATEGORY:-}"

        if [[ -z "${category}" ]]; then
            category="$(
                paperless_category_from_document "${document_id}"
            )"

            if [[ -z "${category}" ]]; then
                category="${PAPERLESS_DEFAULT_CATEGORY}"
            fi

            job_update \
                "${job_id}" \
                "CATEGORY" \
                "${category}"
        fi

        info "Kategorie: ${category}"


        # ----------------------------------------------------
        # Quelle
        # ----------------------------------------------------

        source_file="${SOURCE_FILE:-}"
        source_name="${SOURCE_NAME:-}"
        source_path="${SOURCE_PATH:-}"

        if [[ -z "${source_file}" ]]; then
            error "Job ${job_id}: SOURCE_FILE ist leer."
            continue
        fi

        if [[ -z "${source_name}" ]]; then
            error "Job ${job_id}: SOURCE_NAME ist leer."
            continue
        fi

        if [[ -z "${source_path}" ]]; then
            error "Job ${job_id}: SOURCE_PATH ist leer."

            job_update \
                "${job_id}" \
                "ERROR_TYPE" \
                "SOURCE_PATH_MISSING"

            job_update \
                "${job_id}" \
                "ERROR_MESSAGE" \
                "SOURCE_PATH ist für die Google-Drive-Quelle leer."

            job_set_status \
                "${job_id}" \
                "ARCHIVE_FAILED"

            processed=$((processed + 1))
            continue
        fi


        # ----------------------------------------------------
        # Archivdateiname
        # ----------------------------------------------------

        archive_file="${ARCHIVE_FILE:-}"

        if [[ -z "${archive_file}" ]]; then
            archive_file="$(
                archive_filename_from_job \
                    "${source_name}" \
                    "${job_id}"
            )"

            job_update \
                "${job_id}" \
                "ARCHIVE_FILE" \
                "${archive_file}"
        fi

        info "Archivdateiname: ${archive_file}"


        # ----------------------------------------------------
        # Archivziel
        # ----------------------------------------------------

        archive_target="${ARCHIVE_TARGET:-}"

        if [[ -z "${archive_target}" ]]; then
            if [[ "${NOLLM_APPROVED:-false}" == "true" && -n "${CORRESPONDENT:-}" ]]; then
                archive_target="${GDRIVE_ARCHIVE%/}/${category}/${CORRESPONDENT}"
            else
                archive_target="$(archive_target_from_category "${category}")"
            fi

            job_update \
                "${job_id}" \
                "ARCHIVE_TARGET" \
                "${archive_target}"
        fi

        info "Archivziel: ${archive_target}"


        # ----------------------------------------------------
        # Bereits verifiziert?
        # ----------------------------------------------------

        archive_verified="${ARCHIVE_VERIFIED:-false}"

        if [[ "${archive_verified}" == "true" ]]; then
            info "Archiv ist bereits verifiziert."

            # ------------------------------------------------
            # Google-Drive-Quelle
            # ------------------------------------------------

            remote_source="${GDRIVE_SCAN}/${source_path}"

            info "Originale Google-Drive-Quelle: ${remote_source}"

            gdrive_source_deleted="${GDRIVE_SOURCE_DELETED:-false}"


            # ------------------------------------------------
            # Google-Drive-Quelle löschen und verifizieren
            # ------------------------------------------------

            if [[ "${gdrive_source_deleted}" != "true" ]]; then

                info "Lösche/verifiziere Google-Drive-Quelle: ${remote_source}"

                if ! delete_gdrive_source_and_verify "${remote_source}"; then
                    error "Google-Drive-Quelle konnte nicht sicher gelöscht/verifiziert werden."
                    error "Quelle: ${remote_source}"

                    job_update "${job_id}" "ERROR_TYPE" "GDRIVE_SOURCE_DELETE_FAILED"
                    job_update \
                        "${job_id}" \
                        "ERROR_MESSAGE" \
                        "Google-Drive-Quelle konnte nicht sicher gelöscht/verifiziert werden: ${remote_source}"
                    job_set_status "${job_id}" "ARCHIVE_FAILED"

                    processed=$((processed + 1))
                    continue
                fi

                job_update "${job_id}" "GDRIVE_SOURCE_DELETED" "true"
                info "Google-Drive-Löschung erfolgreich verifiziert."

            fi


            # ------------------------------------------------
            # Lokale Quelle erst jetzt löschen
            # ------------------------------------------------

            local_source_deleted="${LOCAL_SOURCE_DELETED:-false}"

            if [[ "${local_source_deleted}" != "true" ]]; then

                if [[ -n "${source_file}" && -f "${source_file}" ]]; then
                    info "Lösche lokale Quelle: ${source_file}"

                    if rm -f -- "${source_file}"; then

                        job_update \
                            "${job_id}" \
                            "LOCAL_SOURCE_DELETED" \
                            "true"

                        info "Lokale Quelle erfolgreich gelöscht."

                    else

                        error "Lokale Quelle konnte nicht gelöscht werden."

                        job_update \
                            "${job_id}" \
                            "ERROR_TYPE" \
                            "LOCAL_SOURCE_DELETE_FAILED"

                        job_update \
                            "${job_id}" \
                            "ERROR_MESSAGE" \
                            "Lokale Quelle konnte nach erfolgreicher Archiv- und Google-Drive-Verifikation nicht gelöscht werden"

                        job_set_status \
                            "${job_id}" \
                            "ARCHIVE_FAILED"

                        processed=$((processed + 1))
                        continue
                    fi

                else

                    info "Lokale Quelle ist bereits nicht mehr vorhanden."

                    job_update \
                        "${job_id}" \
                        "LOCAL_SOURCE_DELETED" \
                        "true"
                fi

            else
                info "Lokale Quelle ist laut Job bereits gelöscht."
            fi


            # ------------------------------------------------
            # Job vollständig abgeschlossen
            # ------------------------------------------------

            job_update \
                "${job_id}" \
                "COMPLETED_AT" \
                "$(iso_now)"

            job_set_status \
                "${job_id}" \
                "COMPLETE"

            info "Job ${job_id}: COMPLETE"

            processed=$((processed + 1))
            continue
        fi


        # ----------------------------------------------------
        # Status auf ARCHIVE_PROCESSING
        # ----------------------------------------------------

        job_set_status \
            "${job_id}" \
            "ARCHIVE_PROCESSING"


        # ----------------------------------------------------
        # Upload + Verifikation
        # ----------------------------------------------------

        if archive_upload_and_verify \
            "${source_file}" \
            "${archive_target}" \
            "${archive_file}"
        then

            job_update \
                "${job_id}" \
                "ARCHIVE_VERIFIED" \
                "true"

            info "Job ${job_id}: ARCHIVE_VERIFIED=true"
            info "Quellen werden in dieser Stufe NICHT gelöscht."

        else

            error "Job ${job_id}: Archivierung fehlgeschlagen."

            job_update \
                "${job_id}" \
                "ERROR_TYPE" \
                "ARCHIVE_UPLOAD_FAILED"

            job_update \
                "${job_id}" \
                "ERROR_MESSAGE" \
                "Archiv-Upload oder Verifikation fehlgeschlagen"

            job_set_status \
                "${job_id}" \
                "ARCHIVE_FAILED"

            processed=$((processed + 1))
            continue
        fi


        processed=$((processed + 1))
        continue
    fi


    # ========================================================
    # Paperless Task überwachen
    # ========================================================

    task_id="${PAPERLESS_TASK_ID:-}"

    if [[ -z "${task_id}" ]]; then
        error "Job ${job_id}: keine PAPERLESS_TASK_ID vorhanden."
        continue
    fi

    info "Prüfe Job: ${job_id}"
    info "Task-ID: ${task_id}"

    task_status="$(
        paperless_task_status "${task_id}" 2>/dev/null || true
    )"

    task_status="${task_status,,}"

    info "Paperless Task-Status: ${task_status:-unbekannt}"


    case "${task_status}" in

        pending|started|retry)

            info "Task läuft noch. Job bleibt PAPERLESS_PROCESSING."
            ;;


        success)

            document_id="$(
                paperless_task_related_document_id \
                    "${task_id}" \
                    2>/dev/null || true
            )"

            if [[ -z "${document_id}" ]]; then
                error "Job ${job_id}: Task erfolgreich, aber keine Dokument-ID gefunden."
                continue
            fi

            info "Paperless Dokument-ID: ${document_id}"

            job_update \
                "${job_id}" \
                "PAPERLESS_DOCUMENT_ID" \
                "${document_id}"

            job_update \
                "${job_id}" \
                "PAPERLESS_STATUS" \
                "success"


            # noLLM: Tag setzen, Gemini ueberspringen und explizite Freigabe verlangen.
            # Der exakte Pfadbestandteil ist entscheidend; noLLM_alt etc. bleiben normal.
            if nollm_source_path "${SOURCE_PATH:-}"; then
                if ! nollm_tag_document "${document_id}"; then
                    job_update "${job_id}" ERROR_TYPE NOLLM_TAG_FAILED
                    job_update "${job_id}" NOLLM_TAG_PENDING true
                    job_set_status "${job_id}" GEMINI_SKIPPED
                    error "Job ${job_id}: noLLM-Tag konnte nicht gesetzt werden; bleibt ohne Archivfreigabe in der noLLM-Prüfung."
                else
                    job_update "${job_id}" NOLLM_APPROVED false
                    job_set_status "${job_id}" GEMINI_SKIPPED
                    info "Job ${job_id} ist noLLM: Gemini uebersprungen; wartet auf manuelle Freigabe."
                fi
            else
                # Bestehender Gemini-Pfad bleibt unveraendert.
                job_set_status "${job_id}" "GEMINI_PENDING"
                info "Job ${job_id} wartet auf Gemini-Klassifizierung."
            fi

            processed=$((processed + 1))
            ;;


        failure)

            duplicate_of="$(
                paperless_task_duplicate_of \
                    "${task_id}" \
                    2>/dev/null || true
            )"

            if [[ -n "${duplicate_of}" ]]; then

                duplicate_in_trash="$(
                    paperless_task_duplicate_in_trash \
                        "${task_id}" \
                        2>/dev/null || true
                )"

                info "Paperless meldet ein Duplikat."
                info "Duplikat von Dokument: ${duplicate_of}"
                info "Duplikat im Papierkorb: ${duplicate_in_trash}"

                job_update \
                    "${job_id}" \
                    "PAPERLESS_DOCUMENT_ID" \
                    "${duplicate_of}"

                job_update \
                    "${job_id}" \
                    "PAPERLESS_STATUS" \
                    "failure"

                job_update \
                    "${job_id}" \
                    "PAPERLESS_DUPLICATE" \
                    "true"

                job_update \
                    "${job_id}" \
                    "PAPERLESS_DUPLICATE_OF" \
                    "${duplicate_of}"

                job_update \
                    "${job_id}" \
                    "PAPERLESS_DUPLICATE_IN_TRASH" \
                    "${duplicate_in_trash}"

                # ------------------------------------------------
                # DUPLICATE direkt vollständig bereinigen
                # ------------------------------------------------

                if cleanup_duplicate "${job_id}"; then

                    info "Job ${job_id} auf DUPLICATE gesetzt und bereinigt."
                    processed=$((processed + 1))

                else

                    error "Job ${job_id}: Duplikat erkannt, aber Bereinigung fehlgeschlagen."

                    # DUPLICATE bleibt erhalten.
                    # Beim nächsten Lauf wird die Bereinigung erneut versucht.
                    job_set_status \
                        "${job_id}" \
                        "DUPLICATE"

                fi

                continue
            fi


            error "Job ${job_id}: Paperless Task ist fehlgeschlagen."

            # ------------------------------------------------
            # Originale Paperless-Fehlermeldung übernehmen
            # ------------------------------------------------

            error_message="$(
                paperless_task_json \
                    "${task_id}" \
                | jq -r '.result_data.error_message // empty'
            )"

            if [[ -z "${error_message}" ]]; then
                error_message="Paperless Task fehlgeschlagen, aber keine error_message geliefert."
            fi

            error "Paperless Fehler: ${error_message}"

            job_update \
                "${job_id}" \
                "PAPERLESS_STATUS" \
                "failure"

            job_update \
                "${job_id}" \
                "FAILED_AT" \
                "$(iso_now)"

            job_update \
                "${job_id}" \
                "ERROR_TYPE" \
                "PAPERLESS_FAILURE"

            job_update \
                "${job_id}" \
                "ERROR_MESSAGE" \
                "${error_message}"

            job_set_status \
                "${job_id}" \
                "PAPERLESS_FAILED"

            processed=$((processed + 1))
            ;;

        *)

            info "Unbekannter Paperless Task-Status: ${task_status:-<leer>}"
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


info "Verarbeitete Jobs insgesamt: ${processed}"
info "Gemini-Jobs in diesem Lauf: ${gemini_processed}/${GEMINI_MAX_PER_RUN}"
info "=== Ende Script 03 ==="

exit 0
