#!/usr/bin/env bash
# Read-only: OCR-Inhalte und Metadaten lesen; Vorschläge über Gemini erzeugen.
# Speichert zusätzlich die OCR-Textlänge.
# Aufruf: ./scripts/01_analyze.sh [--id NUMMER | --limit ANZAHL]

set -euo pipefail

source "$(dirname "$0")/lib/paperless_api.sh"
source "$(dirname "$0")/lib/llm_api.sh"

mode=limit
value=10

if (( $# > 0 )); then
  if (( $# != 2 )); then
    echo 'Aufruf: 01_analyze.sh [--id NUMMER | --limit ANZAHL | --missing ANZAHL]' >&2
    exit 2
  fi

  case "$1" in
    --id) mode=id ;;
    --limit) mode=limit ;;
    --missing) mode=missing ;;
    *) echo 'Unbekannter Modus' >&2; exit 2 ;;
  esac

  value="$2"
fi

[[ "$value" =~ ^[0-9]+$ ]] || {
  echo 'Positive Ganzzahl erwartet' >&2
  exit 2
}

if [[ "$mode" != id && "$value" -gt "$LLM_MAX_REQUESTS_PER_RUN" ]]; then
  echo "Limit über LLM_MAX_REQUESTS_PER_RUN (${LLM_MAX_REQUESTS_PER_RUN})" >&2
  exit 2
fi

pm_init

[[ -n "${PAPERLESS_TOKEN:-}" && -n "${GEMINI_API_KEY:-}" ]] || {
  echo 'PAPERLESS_TOKEN und GEMINI_API_KEY müssen gesetzt sein.' >&2
  exit 2
}

exec 9>"$PM_STATE/.analyze.lock"
flock -n 9 || {
  echo 'Analyse läuft bereits' >&2
  exit 1
}

# Kataloge sind notwendig für aussagekräftige KI-Vorschläge.
for resource in tags correspondents document_types; do
  pm_paperless_catalog "$resource" |
    pm_atomic_json "$PM_STATE/analysis/${resource}.json"
done

if [[ "$mode" == id ]]; then
  ids="$value"
else
  all_ids="$(pm_paperless_all_ids)"
  if [[ "$mode" == missing ]]; then
    ids=""
    selected=0
    while IFS= read -r candidate; do
      [[ "$candidate" =~ ^[0-9]+$ ]] || continue
      proposal_file="$PM_STATE/proposals/${candidate}.json"
      if [[ -f "$proposal_file" ]] &&
         jq -e . "$proposal_file" >/dev/null 2>&1; then
        continue
      fi
      if [[ -n "$ids" ]]; then ids+=$'\n'; fi
      ids+="$candidate"
      ((selected+=1))
      if (( selected >= value )); then break; fi
    done <<< "$all_ids"
    pm_log INFO "Fehlende Vorschläge ausgewählt: $selected"
  else
    ids="$(printf '%s\n' "$all_ids" | sed -n "1,${value}p")"
  fi
fi

processed=0
failed=0

while IFS= read -r id; do
  [[ -n "$id" ]] || continue

  pm_log INFO "Lese Dokument $id"

  document_file="$(mktemp "${TMPDIR:-/tmp}/pm-document.XXXXXX")"
  request_file="$(mktemp "${TMPDIR:-/tmp}/pm-request.XXXXXX")"
  proposal_file="$(mktemp "${TMPDIR:-/tmp}/pm-proposal.XXXXXX")"

  if ! pm_paperless_document "$id" > "$document_file"; then
    rm -f "$document_file" "$request_file" "$proposal_file"
    ((failed+=1))
    continue
  fi

  # OCR-Text begrenzen; die vollständige Länge wird separat gespeichert.
  jq -n \
      --slurpfile doc "$document_file" \
      --slurpfile tags "$PM_STATE/analysis/tags.json" \
      --slurpfile correspondents "$PM_STATE/analysis/correspondents.json" \
      --slurpfile types "$PM_STATE/analysis/document_types.json" \
      --slurpfile catalog "$PM_ROOT/config/tag_catalog.json" \
      --argjson max "$LLM_MAX_INPUT_CHARS" \
      '($doc[0]) as $doc | {
        catalog: $catalog[0],
        document: {
          id: $doc.id,
          title: $doc.title,
          created: $doc.created,
          original_file_name: $doc.original_file_name,
          mime_type: $doc.mime_type,
          correspondent: $doc.correspondent,
          document_type: $doc.document_type,
          tags: $doc.tags,
          content: (($doc.content // "")[:$max])
        },
        existing_tags: ($tags[0] | map({id, name})),
        existing_correspondents: ($correspondents[0] | map({id, name})),
        existing_document_types: ($types[0] | map({id, name}))
      }' > "$request_file"
  request="$(cat "$request_file")"

  if ! proposal="$(pm_llm_classify "$request")"; then
    pm_log ERROR "KI-Anfrage für Dokument $id fehlgeschlagen"
    ((failed+=1))
    continue
  fi

  # Gemini-Ausgabe auf Pflichtfelder und Prüfregel kontrollieren.
  if ! jq -e '
      (.primary_tag | type == "string") and
      (.additional_tags | type == "array") and
      (.correspondent == null or (.correspondent | type == "string")) and
      (.correspondent_suggestion == null or (.correspondent_suggestion | type == "string")) and
      (.document_date == null or (.document_date | type == "string")) and
      (.confidence | type == "number" and . >= 0 and . <= 1) and
      (.requires_review | type == "boolean") and
      (.reason | type == "string")
    ' >/dev/null 2>&1 <<< "$proposal"; then
    pm_log ERROR "Ungültige KI-Ausgabe für Dokument $id; Vorschlag wird nicht gespeichert"
    ((failed+=1))
    continue
  fi

  # Formale Validierung und regelbasierte Prüfentscheidung.
  # Ohne OCR darf das Importdatum nicht als Dokumentdatum übernommen werden.
  printf '%s\n' "$proposal" > "$proposal_file"
  proposal="$(jq --slurpfile request "$request_file" --slurpfile document "$document_file" '
    ($request[0]) as $request
    | ($document[0]) as $document
    | . as $p
    | (if (($request.document.content // "") | length) == 0
          and $p.document_date != null
          and $p.document_date == ($document.created // "")
       then null
       else $p.document_date
       end) as $checked_date
    | .document_date = $checked_date
    | [
        if (($request.catalog.main_categories // [])
            | index($p.primary_tag)) == null
        then "Hauptkategorie fehlt im Katalog"
        else empty end,

        if ($p.document_date != null)
           and (($p.document_date
                 | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")) | not)
        then "Dokumentdatum hat kein gültiges YYYY-MM-DD-Format"
        else empty end,

        if (($request.document.content // "") | length) == 0
           and $p.document_date != null
           and $p.document_date == ($document.created // "")
        then "Kein OCR-Text; Datum entspricht dem Importdatum und wurde verworfen"
        else empty end,

        if (($p.additional_tags | length) > 5)
        then "Mehr als fünf zusätzliche Tags vorgeschlagen"
        else empty end,

        if (($p.additional_tags | unique | length)
            != ($p.additional_tags | length))
        then "Doppelte zusätzliche Tags vorgeschlagen"
        else empty end
      ] as $warnings
    | .validation_warnings = $warnings
    | .requires_review =
        (($warnings | length) > 0)
        or ($p.requires_review == true
            and ($p.reason | startswith("Prüfgrund:")))
    | .review_decision =
        if .requires_review == true
        then "manual_check"
        elif .confidence < 0.7
        then "inconclusive"
        else "no_check_needed"
        end
  ' <<< "$proposal")"

  if jq -e '.validation_warnings | length > 0' >/dev/null <<< "$proposal"; then
    pm_log WARN "Dokument $id: Validierungswarnungen vorhanden"
  fi

  printf '%s\n' "$proposal" > "$proposal_file"

  jq -n \
    --slurpfile document "$document_file" \
    --slurpfile request "$request_file" \
    --slurpfile proposal "$proposal_file" \
    --arg provider "$LLM_PROVIDER" \
    --arg model "$GEMINI_MODEL" \
    --arg generated "$(date -Is)" \
    '($document[0]) as $document
     | ($request[0]) as $request
     | ($proposal[0]) as $proposal
     | {
      document_id: $document.id,
      existing: {
        title: $document.title,
        created: $document.created,
        original_file_name: $document.original_file_name,
        archived_file_name: $document.archived_file_name,
        correspondent: $document.correspondent,
        tags: $document.tags,
        document_type: $document.document_type
      },
      analysis: {
        ocr_char_count: (($document.content // "") | length),
        ocr_sent_char_count: (($request.document.content // "") | length)
      },
      proposal: $proposal,
      provider: $provider,
      model: $model,
      generated_at: $generated,
      applied: false
    }' |
    pm_atomic_json "$PM_STATE/proposals/${id}.json"

  rm -f "$document_file" "$request_file" "$proposal_file"
  pm_log INFO "Vorschlag gespeichert: Dokument $id (keine Änderungen an Paperless)"
  ((processed+=1))
done <<< "$ids"

pm_log INFO "Abgeschlossen: $processed Vorschläge, $failed Fehler"
((failed == 0))
