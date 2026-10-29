#!/usr/bin/env bash
# Read-only: OCR-Inhalte und Metadaten lesen; Vorschläge über Gemini erzeugen.
# Speichert zusätzlich die OCR-Textlänge.
# Aufruf: ./scripts/01_analyze_doc.sh [--id NUMMER | --limit ANZAHL]

set -euo pipefail

source "$(dirname "$0")/lib/paperless_api.sh"
source "$(dirname "$0")/lib/llm_api.sh"

mode=limit
value=10

if (( $# > 0 )); then
  if (( $# != 2 )); then
    echo 'Aufruf: 01_analyze_doc.sh [--id NUMMER | --limit ANZAHL | --missing ANZAHL]' >&2
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


# ------------------------------------------------------------
# Index der bereits analysierten Dokumente
# ------------------------------------------------------------

ANALYZED_IDS_FILE="$PM_STATE/analyzed_ids.json"
declare -A ANALYZED_IDS=()

rebuild_analyzed_index() {
  local file base id
  local ids_tmp

  ids_tmp="$(mktemp "${TMPDIR:-/tmp}/pm-analyzed-ids.XXXXXX")"

  # Nur gültige Proposal-Dateien übernehmen.
  shopt -s nullglob
  for file in "$PM_STATE"/proposals/*.json; do
    base="${file##*/}"
    id="${base%.json}"

    [[ "$id" =~ ^[0-9]+$ ]] || continue

    if jq -e --argjson id "$id" '
      .document_id == $id
      and (.proposal | type == "object")
    ' "$file" >/dev/null 2>&1; then
      printf '%s\n' "$id" >> "$ids_tmp"
    fi
  done
  shopt -u nullglob

  # IDs numerisch als JSON-Array speichern.
  jq -Rsc '
    split("\n")
    | map(select(length > 0) | tonumber)
    | unique
  ' "$ids_tmp" | pm_atomic_json "$ANALYZED_IDS_FILE"

  rm -f "$ids_tmp"
  pm_log INFO "Analyseindex neu aufgebaut: $(jq 'length' "$ANALYZED_IDS_FILE") IDs"
}

save_analyzed_index() {
  printf '%s\n' "${!ANALYZED_IDS[@]}" |
    sort -n |
    jq -Rsc '
      split("\n")
      | map(select(length > 0) | tonumber)
      | unique
    ' |
    pm_atomic_json "$ANALYZED_IDS_FILE"
}

# Fehlt der Index oder ist er ungültig, einmalig neu aufbauen.
if [[ ! -f "$ANALYZED_IDS_FILE" ]] ||
   ! jq -e '
     type == "array"
     and all(.[]; type == "number" and floor == . and . > 0)
   ' "$ANALYZED_IDS_FILE" >/dev/null 2>&1; then
  pm_log INFO "Analyseindex fehlt oder ist ungültig; baue ihn neu auf"
  rebuild_analyzed_index
fi

# Index in eine Bash-Map laden: schnelle Prüfung im Speicher.
while IFS= read -r analyzed_id; do
  [[ "$analyzed_id" =~ ^[0-9]+$ ]] || continue
  ANALYZED_IDS["$analyzed_id"]=1
done < <(jq -r '.[]' "$ANALYZED_IDS_FILE")



# Kataloge sind notwendig für aussagekräftige KI-Vorschläge.
for resource in tags correspondents document_types; do
  pm_paperless_catalog "$resource" |
    pm_atomic_json "$PM_STATE/analysis/${resource}.json"
done

if ! NO_LLM_TAG_ID="$(pm_paperless_tag_id_by_name noLLM)"; then
  pm_log ERROR "Paperless-Tag-Katalog konnte nicht sicher gelesen werden; Abbruch"
  exit 1
fi

if [[ -n "$NO_LLM_TAG_ID" ]]; then
  pm_log INFO "Schutz-Tag noLLM gefunden: ID $NO_LLM_TAG_ID"
else
  pm_log WARN "Tag noLLM fehlt; Gemini-Verarbeitung läuft ohne Tag-Filter weiter"
fi


if [[ "$mode" == id ]]; then
  ids="$value"
else
  # Alle Paperless-IDs holen; die Auswahl geeigneter Dokumente
  # erfolgt in der Verarbeitung anhand des Index.
  ids="$(pm_paperless_all_ids)"
fi

processed=0
failed=0
gemini_requests=0

while IFS= read -r id; do
  [[ -n "$id" ]] || continue


  # Bereits indexierte Dokumente nicht erneut prüfen.
  if [[ "$mode" != id ]] && [[ -n "${ANALYZED_IDS[$id]:-}" ]]; then
    continue
  fi

  target_proposal="$PM_STATE/proposals/${id}.json"

  # Schutz gegen Abbruch nach dem Speichern eines Proposals,
  # aber vor der letzten Indexaktualisierung.
  if [[ "$mode" != id ]] &&
     [[ -f "$target_proposal" ]] &&
     jq -e --argjson id "$id" '
       .document_id == $id
       and (.proposal | type == "object")
     ' "$target_proposal" >/dev/null 2>&1; then
    ANALYZED_IDS["$id"]=1
    save_analyzed_index
    pm_log INFO "Dokument $id: gültiges Proposal nachträglich indexiert"
    continue
  fi


  # Bei --limit und --missing maximal die gewünschte Anzahl
  # Gemini-Anfragen starten. noLLM-Dokumente zählen nicht.
  if [[ "$mode" != id ]] && (( gemini_requests >= value )); then
    pm_log INFO "Gemini-Limit erreicht: $gemini_requests Anfragen"
    break
  fi

  target_proposal="$PM_STATE/proposals/${id}.json"

  # Bei regulären Läufen nur Dokumente ohne gültiges Proposal
  # berücksichtigen. --id bleibt eine gezielte Einzelanalyse.
  if [[ "$mode" != id ]] &&
     [[ -f "$target_proposal" ]] &&
     jq -e --argjson id "$id" '
       .document_id == $id
       and (.proposal | type == "object")
     ' "$target_proposal" >/dev/null 2>&1; then
    pm_log INFO "Dokument $id übersprungen: Proposal bereits vorhanden"
    continue
  fi

  pm_log INFO "Lese Dokument $id"

  document_file="$(mktemp "${TMPDIR:-/tmp}/pm-document.XXXXXX")"
  request_file="$(mktemp "${TMPDIR:-/tmp}/pm-request.XXXXXX")"
  proposal_file="$(mktemp "${TMPDIR:-/tmp}/pm-proposal.XXXXXX")"


if ! pm_paperless_document "$id" > "$document_file"; then
  rm -f "$document_file" "$request_file" "$proposal_file"
  pm_log ERROR "Dokument $id konnte nicht gelesen werden; keine Gemini-Anfrage"
  ((failed+=1))
  continue
fi

# Tag-Struktur prüfen; bei unerwarteter Antwort keine Gemini-Anfrage.
if ! jq -e '.tags | type == "array"' \
    "$document_file" >/dev/null 2>&1; then
  rm -f "$document_file" "$request_file" "$proposal_file"
  pm_log ERROR "Dokument $id: Tags nicht lesbar; keine Gemini-Anfrage"
  ((failed+=1))
  continue
fi

# noLLM: niemals Gemini aufrufen; fehlendes Proposal fuer
# manuelle Bearbeitung erzeugen.
if [[ -n "$NO_LLM_TAG_ID" ]] && jq -e --argjson tag_id "$NO_LLM_TAG_ID" \
    '(.tags | index($tag_id)) != null' \
    "$document_file" >/dev/null; then

  target_proposal="$PM_STATE/proposals/${id}.json"

  if [[ -f "$target_proposal" ]] &&
     jq -e --argjson id "$id" '
       .document_id == $id
       and (.proposal | type == "object")
     ' "$target_proposal" >/dev/null 2>&1; then
    pm_log INFO "Dokument $id: vorhandenes Proposal bleibt unveraendert"
  else
    jq -n \
      --slurpfile document "$document_file" \
      --arg generated "$(date -Is)" \
      '($document[0]) as $document
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
            ocr_sent_char_count: 0
          },
          proposal: {
            requires_review: true,
            review_decision: "manual_check",
            validation_warnings: [
              "Tag noLLM: keine Gemini-Analyse; manuelle Bearbeitung erforderlich"
            ],
            reason: "Manuelle Bearbeitung erforderlich: Dokument ist mit noLLM markiert."
          },
          provider: "none",
          model: "manual-noLLM",
          generated_at: $generated,
          applied: false
        }' |
      pm_atomic_json "$target_proposal"

    pm_log INFO "Dokument $id: manuelles noLLM-Placeholder-Proposal gespeichert"
  fi

  # noLLM wurde manuell abgelegt oder war bereits gültig.
  ANALYZED_IDS["$id"]=1
  save_analyzed_index

  rm -f "$document_file" "$request_file" "$proposal_file"
  ((processed+=1))
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

  # Nur tatsächliche Gemini-Anfragen zählen.
  # Der Zähler wird auch bei einem fehlgeschlagenen Aufruf erhöht,
  # damit das Limit pro Lauf eingehalten wird.
  ((gemini_requests+=1))
  pm_log INFO "Gemini-Anfrage $gemini_requests/$value für Dokument $id"

  if ! proposal="$(pm_llm_classify "$request")"; then
    pm_log ERROR "KI-Anfrage für Dokument $id fehlgeschlagen"
    ((failed+=1))
    continue
  fi

  # Gemini-Ausgabe auf Pflichtfelder und Prüfregel kontrollieren.
  if ! jq -e '
      has("title") and
      (.title == null or
        (.title | type == "string" and length > 0 and length <= 160)) and
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
    | .requires_review = false
    | .review_decision = "no_check_needed"
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

# Gemini-Vorsch-Vorschlag für das Apply-Script vormerken.
APPLY_INDEX="$PM_STATE/apply_candidates.json"
mkdir -p "$PM_STATE"

# Fehlenden oder ungültigen Index initialisieren.
if [[ ! -f "$APPLY_INDEX" ]] ||
   ! jq -e '
     type == "array" and
     all(.[]; type == "number" and floor == . and . > 0)
   ' "$APPLY_INDEX" >/dev/null 2>&1; then

  echo "[INFO] Apply-Index fehlt oder ist ungültig; baue ihn neu auf."

  index_tmp="$(mktemp "${TMPDIR:-/tmp}/pm-apply-index.XXXXXX")"
  proposal_ids_tmp="$(mktemp "${TMPDIR:-/tmp}/pm-apply-ids.XXXXXX")"

  shopt -s nullglob
  for proposal_file in "$PM_STATE"/proposals/*.json; do
    jq -er '
      select(
        .applied != true and
        (.document_id | numbers) and
        (.proposal | type == "object") and
        (.model != "manual-noLLM") and
        (.provider != "none") and
        ((.proposal.primary_tag // "") | type == "string" and length > 0)
      ) | .document_id
    ' "$proposal_file" 2>/dev/null >> "$proposal_ids_tmp" || true
  done
  shopt -u nullglob

  if ! sort -nu "$proposal_ids_tmp" |
       jq -Rsc '
         split("\n")
         | map(select(test("^[0-9]+$")) | tonumber)
       ' > "$index_tmp"; then
    rm -f "$index_tmp" "$proposal_ids_tmp"
    echo "[FEHLER] Apply-Index konnte nicht aufgebaut werden." >&2
    exit 1
  fi

  if ! jq -e '
    type == "array" and
    all(.[]; type == "number" and floor == . and . > 0)
  ' "$index_tmp" >/dev/null; then
    rm -f "$index_tmp" "$proposal_ids_tmp"
    echo "[FEHLER] Neu aufgebauter Apply-Index ist ungültig." >&2
    exit 1
  fi

  mv "$index_tmp" "$APPLY_INDEX"
  rm -f "$proposal_ids_tmp"
fi

# Aktuelle Dokument-ID immer ergänzen, falls sie noch fehlt.
index_tmp="$(mktemp "${TMPDIR:-/tmp}/pm-apply-add.XXXXXX")"

if ! jq --argjson id "$id" '
  if index($id) == null then . + [$id] else . end
  | sort
  | unique
' "$APPLY_INDEX" > "$index_tmp"; then
  rm -f "$index_tmp"
  echo "[FEHLER] Dokument $id: Apply-Index konnte nicht aktualisiert werden." >&2
  exit 1
fi

if ! jq -e '
  type == "array" and
  all(.[]; type == "number" and floor == . and . > 0)
' "$index_tmp" >/dev/null; then
  rm -f "$index_tmp"
  echo "[FEHLER] Dokument $id: neuer Apply-Index ist ungültig." >&2
  exit 1
fi

if ! mv "$index_tmp" "$APPLY_INDEX"; then
  rm -f "$index_tmp"
  echo "[FEHLER] Dokument $id: Apply-Index konnte nicht gespeichert werden." >&2
  exit 1
fi

echo "[INFO] Dokument $id zum Apply-Index hinzugefügt."

  # Erst nach erfolgreichem Speichern des Proposals indexieren.
  ANALYZED_IDS["$id"]=1
  save_analyzed_index

  rm -f "$document_file" "$request_file" "$proposal_file"
  pm_log INFO "Vorschlag gespeichert und indexiert: Dokument $id (keine Änderungen an Paperless)"
  ((processed+=1))
done <<< "$ids"

pm_log INFO "Abgeschlossen: $processed Vorschläge, $failed Fehler, $gemini_requests Gemini-Anfragen"
((failed == 0))
