#!/usr/bin/env bash
# ============================================================
# 04_tag_imported_docs.sh - Direktimport-Erkennung / DRY-RUN mit --id
# DRY-RUN oder einmalige Job-Erzeugung fuer Dokument 922; keine Paperless-API-Schreibzugriffe
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/jobs.sh"
source "${SCRIPT_DIR}/lib/paperless_api.sh"

LEGACY_MAX_DOCUMENT_ID=870
REGISTRY_FILE="${STATE_DIR}/imported_docs_registry.tsv"
METADATA_ROOT="${METADATA_ROOT:-/home/pi/docker/paperless/paperless_metadata}"
PROPOSAL_DIR="${PROPOSAL_DIR:-${STATE_DIR}/metadata/proposals}"
ARCHIVE_REMOTE="${GDRIVE_ARCHIVE:-gdrive:PAPERLESS}"
PAGE_SIZE=100
TARGET_ID=""
APPLY_MODE=false

# Schreibzugriffe bleiben gesperrt. Optional genau eine Dokument-ID prüfen.
while (( $# )); do
    case "$1" in
        --dry-run) shift ;;
        --apply) APPLY_MODE=true; shift ;;
        --id)
            [[ $# -ge 2 && "$2" =~ ^[0-9]+$ && "$2" != 0 ]] || {
                echo 'FEHLER: --id benötigt eine positive Dokument-ID.' >&2; exit 1;
            }
            TARGET_ID="$2"
            shift 2
            ;;
        *) echo "Verwendung: $0 [--dry-run|--apply] --id DOKUMENT_ID" >&2; exit 1 ;;
    esac
done

# Bewusst auf genau ein Dokument begrenzter Integrationstest.
if [[ "$APPLY_MODE" == true ]]; then
    [[ "$TARGET_ID" == 922 ]] || { echo 'FEHLER: --apply ist nur fuer --id 922 freigeschaltet.' >&2; exit 1; }
fi

# Job nur anlegen, nicht Skript 03 ausfuehren. Keine Registry-Schreibzugriffe.
create_test_job_922() {
    local id=922
    local source_file='/media/BlueDisc3/PAPERLESS/media/documents/originals/2026/CTS EVENTIM AG & Co. KGaA/Personalausweis Barbara.pdf'
    local source_name='PP_BC_201801.pdf'
    local proposal="${PROPOSAL_DIR}/922.json"
    local doc job_id

    [[ -f "$source_file" && ! -L "$source_file" ]] || { echo 'FEHLER: Originaldatei fehlt oder ist Symlink.' >&2; return 1; }
    [[ "$(realpath -e -- "$source_file")" == /media/BlueDisc3/PAPERLESS/media/documents/originals/* ]] || {
        echo 'FEHLER: Original liegt ausserhalb des Paperless-Originalbereichs.' >&2; return 1;
    }
    [[ -f "$proposal" ]] || { echo 'FEHLER: Proposal fehlt.' >&2; return 1; }
    jq -e --argjson id "$id" '
        .document_id == $id and .applied == false and
        ((.manual_review.approved_at // "") | length > 0) and
        .proposal.requires_review == false and
        .proposal.review_decision == "no_check_needed" and
        ((.proposal.validation_warnings // []) | length == 0) and
        ((.proposal.primary_tag // "") | length > 0)
    ' "$proposal" >/dev/null || { echo 'FEHLER: Proposal ist nicht freigegeben oder ungueltig.' >&2; return 1; }

    # Sicherstellen, dass Paperless ID 922 weiterhin denselben Originalnamen hat.
    doc="$(paperless_curl "$(paperless_api_url 'documents/922/')")" || return 1
    jq -e --arg name "$source_name" '.id == 922 and .original_file_name == $name' <<< "$doc" >/dev/null || {
        echo 'FEHLER: Paperless-Dokumentdaten weichen vom Test ab.' >&2; return 1;
    }
    if [[ -f "$REGISTRY_FILE" ]] && awk -F '\t' '$1 == "922" {found=1} END {exit !found}' "$REGISTRY_FILE"; then
        echo 'FEHLER: Dokument 922 ist bereits in der Registry.' >&2; return 1
    fi
    declare -F job_find_by_document_id >/dev/null || { echo "FEHLER: job_find_by_document_id fehlt in jobs.sh." >&2; return 1; }
    if job_find_by_document_id 922 >/dev/null; then
        echo 'FEHLER: Dokument 922 hat bereits einen Job.' >&2; return 1
    fi
    if job_find_by_source_path 'PAPERLESS_DIRECT/922' >/dev/null; then
        echo 'FEHLER: Direktimport-Quellpfad bereits vergeben.' >&2; return 1
    fi

    job_id="$(job_create "$source_name" "$source_file" 'PAPERLESS_DIRECT/922')" || return 1
    # Erst alle Felder setzen, dann als LETZTEN Schritt den aktiven Status.
    job_update "$job_id" IMPORT_SOURCE PAPERLESS_DIRECT
    job_update "$job_id" PAPERLESS_DOCUMENT_ID 922
    job_update "$job_id" NOLLM_DIRECT false
    job_update "$job_id" PAPERLESS_STATUS success
    job_set_status "$job_id" REVIEW_APPROVED
    printf '\nTESTJOB ANGELEGT (Skript 03 wurde NICHT gestartet):\nJOB_ID=%s\nJOB_DATEI=%s\nSTATUS=REVIEW_APPROVED\n' "$job_id" "$(job_file "$job_id")"
}

if [[ "$APPLY_MODE" == true ]]; then
    [[ -n "${PAPERLESS_TOKEN:-}" ]] || { echo 'FEHLER: PAPERLESS_TOKEN fehlt.' >&2; exit 1; }
    [[ -d "$JOB_DIR" && -d "$PROPOSAL_DIR" ]] || { echo 'FEHLER: Job-/Proposal-Verzeichnis fehlt.' >&2; exit 1; }
    for cmd in jq realpath awk; do command -v "$cmd" >/dev/null || exit 1; done
    create_test_job_922
    exit $?
fi

[[ -n "${PAPERLESS_TOKEN:-}" ]] || { echo 'FEHLER: PAPERLESS_TOKEN fehlt.' >&2; exit 1; }
[[ -d "$JOB_DIR" ]] || { echo "FEHLER: JOB_DIR fehlt: $JOB_DIR" >&2; exit 1; }
[[ -d "$PROPOSAL_DIR" ]] || { echo "FEHLER: Proposal-Verzeichnis fehlt: $PROPOSAL_DIR" >&2; exit 1; }
for cmd in curl jq find grep sort mktemp sed awk head; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "FEHLER: Kommando fehlt: $cmd" >&2; exit 1; }
done

TMP_DIR_04="$(mktemp -d)"
trap 'rm -rf -- "$TMP_DIR_04"' EXIT
JOB_IDS_FILE="$TMP_DIR_04/job_ids"
REGISTRY_IDS_FILE="$TMP_DIR_04/registry_ids"
ARCHIVE_LIST="$TMP_DIR_04/archive_paths"
ARCHIVE_INDEX="$TMP_DIR_04/archive_index.tsv"
: > "$JOB_IDS_FILE"
: > "$REGISTRY_IDS_FILE"

while IFS= read -r -d '' job_file; do
    document_id="$(sed -nE 's/^PAPERLESS_DOCUMENT_ID=([0-9]+)$/\1/p' "$job_file" | head -n 1)"
    if [[ "$document_id" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$document_id" >> "$JOB_IDS_FILE"
    fi
done < <(find "$JOB_DIR" -mindepth 2 -maxdepth 2 -type f -name job.conf -print0)
sort -u -o "$JOB_IDS_FILE" "$JOB_IDS_FILE"

if [[ -f "$REGISTRY_FILE" ]]; then
    awk -F '\t' '$1 ~ /^[0-9]+$/ {print $1}' "$REGISTRY_FILE" | sort -u > "$REGISTRY_IDS_FILE"
fi

# Archivierung ist für die Direktimport-Erkennung nicht Voraussetzung.
# Insbesondere soll ein rclone-Fehler die Gemini-Aufnahme nicht blockieren.
# Die bisherige Archivdateinamen-Prüfung wird daher hier bewusst nicht ausgeführt.
: > "$ARCHIVE_INDEX"

# Alle Tags paginieren; bei unvollstaendiger Tag-Liste nicht falsch als non-noLLM einstufen.
nollm_tag_id=''
tags_url="$(paperless_api_url 'tags/?page_size=100')"
while [[ -n "$tags_url" ]]; do
    tags_response="$(paperless_curl "$tags_url")"
    found_id="$(jq -r '[.results[]? | select(.name == "noLLM") | .id] | first // empty' <<< "$tags_response")"
    if [[ -n "$found_id" ]]; then nollm_tag_id="$found_id"; fi
    next_url="$(jq -r '.next // empty' <<< "$tags_response")"
    if [[ -z "$next_url" ]]; then tags_url=''
    elif [[ "$next_url" == http://* || "$next_url" == https://* ]]; then tags_url="$next_url"
    elif [[ "$next_url" == /* ]]; then tags_url="${PAPERLESS_URL%/}${next_url}"
    else echo 'FEHLER: Unerwartete Tag-Pagination-URL.' >&2; exit 1; fi
done

examined=0 legacy=0 existing_jobs=0 existing_registry=0 candidates=0 nollm_candidates=0
proposal_none=0 proposal_unapproved=0 proposal_approved_unapplied=0
proposal_applied_approved=0 proposal_applied_unapproved=0 proposal_invalid=0
archive_found=0 archive_missing=0 archive_multiple=0
pending_nollm=0 pending_gemini=0 pending_with_proposal=0 pending_without_proposal=0

echo '=== Paperless Direktimport-Erkennung (DRY-RUN) ==='
echo "Legacy-Grenze: $LEGACY_MAX_DOCUMENT_ID"
echo "Proposal-Verzeichnis: $PROPOSAL_DIR"
echo "Archiv: nicht abgefragt (Gemini-Einstieg unabhängig von rclone)"
echo "Dokumentfilter: ${TARGET_ID:-alle ab ID $((LEGACY_MAX_DOCUMENT_ID + 1))}"
echo "noLLM-Tag-ID: ${nollm_tag_id:-nicht vorhanden}"
echo

url="$(paperless_api_url "documents/?page_size=${PAGE_SIZE}&ordering=id")"
while [[ -n "$url" ]]; do
    response="$(paperless_curl "$url")"
    while IFS= read -r document; do
        [[ -n "$document" ]] || continue
        id="$(jq -r '.id // empty' <<< "$document")"
        [[ "$id" =~ ^[0-9]+$ ]] || continue
        if [[ -n "$TARGET_ID" && "$id" != "$TARGET_ID" ]]; then continue; fi
        examined=$((examined + 1))
        if (( 10#$id <= LEGACY_MAX_DOCUMENT_ID )); then
            legacy=$((legacy + 1)); continue
        fi
        if grep -Fxq -- "$id" "$JOB_IDS_FILE"; then
            existing_jobs=$((existing_jobs + 1)); continue
        fi
        if grep -Fxq -- "$id" "$REGISTRY_IDS_FILE"; then
            existing_registry=$((existing_registry + 1)); continue
        fi

        candidates=$((candidates + 1))
        title="$(jq -r '.title // ""' <<< "$document")"
        original_name="$(jq -r '.original_file_name // ""' <<< "$document")"
        added="$(jq -r '.added // ""' <<< "$document")"
        has_nollm=false
        if [[ -n "$nollm_tag_id" ]] && jq -e --argjson tag_id "$nollm_tag_id" '(.tags // []) | index($tag_id) != null' <<< "$document" >/dev/null; then
            has_nollm=true
            nollm_candidates=$((nollm_candidates + 1))
        fi

        proposal="$PROPOSAL_DIR/$id.json"
        proposal_status='KEIN_PROPOSAL'
        if [[ ! -f "$proposal" ]]; then
            proposal_none=$((proposal_none + 1))
        elif ! jq -e 'type == "object" and (.proposal | type == "object")' "$proposal" >/dev/null 2>&1; then
            proposal_status='PROPOSAL_UNGUELTIG'
            proposal_invalid=$((proposal_invalid + 1))
        else
            applied="$(jq -r 'if .applied == true then "true" else "false" end' "$proposal")"
            approved="$(jq -r 'if ((.manual_review.approved_at // "") | length) > 0 then "true" else "false" end' "$proposal")"
            if [[ "$applied" == true && "$approved" == true ]]; then
                proposal_status='ANGEWENDET_UND_FREIGEGEBEN'
                proposal_applied_approved=$((proposal_applied_approved + 1))
            elif [[ "$applied" == true ]]; then
                proposal_status='ANGEWENDET_OHNE_FREIGABENACHWEIS'
                proposal_applied_unapproved=$((proposal_applied_unapproved + 1))
            elif [[ "$approved" == true ]]; then
                proposal_status='FREIGEGEBEN_NICHT_ANGEWENDET'
                proposal_approved_unapplied=$((proposal_approved_unapplied + 1))
            else
                proposal_status='ANALYSIERT_NICHT_FREIGEGEBEN'
                proposal_unapproved=$((proposal_unapproved + 1))
            fi
        fi

        # Ein Archiv-Dateiname ist ein Indiz, KEINE Integritaetsverifikation.
        archive_paths="$(awk -F '\t' -v id="$id" '$1 == id {print $2}' "$ARCHIVE_INDEX")"
        if [[ -n "$archive_paths" ]]; then
            archive_found=$((archive_found + 1))
            matches="$(printf '%s\n' "$archive_paths" | wc -l)"
            if (( matches > 1 )); then
                archive_multiple=$((archive_multiple + 1))
                archive_status="MEHRFACHER DATEINAMEN-TREFFER ($matches) - MANUELL PRUEFEN"
            else
                archive_status="DATEINAME IM ARCHIV GEFUNDEN (NICHT VERIFIZIERT)"
            fi
            action="Archivtreffer separat prüfen"
        else
            archive_missing=$((archive_missing + 1))
            archive_status="NICHT GEPRUEFT"
            if [[ "$proposal_status" == KEIN_PROPOSAL ]]; then
                pending_without_proposal=$((pending_without_proposal + 1))
            else
                pending_with_proposal=$((pending_with_proposal + 1))
            fi
            if [[ "$has_nollm" == true ]]; then
                pending_nollm=$((pending_nollm + 1))
                action="Offen: noLLM/Freigabe pruefen (kein Gemini)"
            else
                pending_gemini=$((pending_gemini + 1))
                action="Offen: Proposal/Freigabe pruefen; ggf. Gemini"
            fi
        fi
        # Detailabfrage nur für gezielte Einzelprüfung; Paperless-API liefert
        # möglicherweise keinen Host-Dateisystempfad. Keine Annahmen treffen.
        if [[ -n "$TARGET_ID" ]]; then
            detail="$(paperless_curl "$(paperless_api_url "documents/${id}/")")"
            printf 'Paperless API Detail (relevante Felder):\n'
            jq '{id, original_file_name, archived_file_name, storage_path, archive_serial_number, added, created, tags, correspondent, title}' <<< "$detail"
            echo 'HINWEIS: Ein verifizierter lokaler Originalpfad ist damit noch nicht ermittelt.'
        fi
        echo '--------------------------------------------------'
        printf 'Dokument-ID   : %s\nTitel         : %s\nDateiname     : %s\nImportiert    : %s\nnoLLM         : %s\nProposal      : %s\nArchivierung  : %s\nAktion        : %s\n' \
            "$id" "$title" "$original_name" "$added" "$has_nollm" "$proposal_status" "$archive_status" "$action"
        if [[ -n "$archive_paths" ]]; then
            printf 'Archivpfad(e):\n%s\n' "$archive_paths"
        fi
    done < <(jq -c '.results[]' <<< "$response")

    next_url="$(jq -r '.next // empty' <<< "$response")"
    if [[ -z "$next_url" ]]; then url=''
    elif [[ "$next_url" == http://* || "$next_url" == https://* ]]; then url="$next_url"
    elif [[ "$next_url" == /* ]]; then url="${PAPERLESS_URL%/}${next_url}"
    else echo 'FEHLER: Unerwartete Dokument-Pagination-URL.' >&2; exit 1; fi
done

cat <<RESULT

==================================================
ERGEBNIS DRY-RUN
==================================================
Untersuchte Dokumente           : $examined
Legacy (ID <= 870)              : $legacy
Mit vorhandenem Job             : $existing_jobs
Bereits in Registry             : $existing_registry
Job-Kandidaten                  : $candidates
Davon noLLM                     : $nollm_candidates

Proposal fehlt                  : $proposal_none
Analysiert, nicht freigegeben   : $proposal_unapproved
Freigegeben, nicht angewendet   : $proposal_approved_unapplied
Angewendet und freigegeben      : $proposal_applied_approved
Angewendet ohne Freigabenachweis: $proposal_applied_unapproved
Proposal ungueltig              : $proposal_invalid

Archiv-Dateiname gefunden (nicht geprüft)       : $archive_found
Davon mehrfache Treffer         : $archive_multiple
Ohne Archivprüfung  : $archive_missing

Ohne Archivprüfung, mit Proposal      : $pending_with_proposal
Ohne Archivprüfung, ohne Proposal     : $pending_without_proposal
Ohne Archivprüfung, noLLM            : $pending_nollm
Ohne Archivprüfung, nicht noLLM      : $pending_gemini

Hinweis: Archiv-Dateinamen wurden in dieser Version nicht abgefragt.
         Die Archivstatistik unten ist daher NICHT aussagekraeftig.
         Keine automatische Job-Erzeugung oder Loeschung.
Es wurden keine Änderungen durchgeführt.
RESULT
