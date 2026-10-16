#!/usr/bin/env bash
# Vollständiger Paperless-Dry-run als CSV.
# Ausschließlich GET-Zugriffe auf Paperless; keine Metadatenänderungen.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/paperless_api.sh"

pm_init

[[ -n "${PAPERLESS_TOKEN:-}" ]] || {
  echo "PAPERLESS_TOKEN fehlt." >&2
  exit 2
}

for cmd in jq; do
  command -v "$cmd" >/dev/null || {
    echo "Benötigtes Programm fehlt: $cmd" >&2
    exit 2
  }
done

REPORT_DIR="$PM_STATE/reports"
mkdir -p "$REPORT_DIR"
STAMP="$(date +%Y-%m-%d_%H%M%S)"
REPORT="$REPORT_DIR/paperless_dryrun_${STAMP}.csv"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Lese Paperless-Kataloge ..."
pm_paperless_catalog tags > "$TMP/tags.json"
pm_paperless_catalog correspondents > "$TMP/correspondents.json"

: > "$TMP/documents.jsonl"
: > "$TMP/errors.txt"

echo "Lese Dokument-IDs ..."
ids="$(pm_paperless_all_ids)"

total="$(printf '%s\n' "$ids" | grep -cE '^[0-9]+$' || true)"
count=0

while IFS= read -r id; do
  [[ "$id" =~ ^[0-9]+$ ]] || continue
  count=$((count + 1))

  if ! doc="$(pm_paperless_document "$id")"; then
    printf '%s\tAPI-LESFEHLER\n' "$id" >> "$TMP/errors.txt"
    jq -cn --arg id "$id" \
      '{document: {id: ($id|tonumber)}, proposal: null, fetch_error: true}' \
      >> "$TMP/documents.jsonl"
    continue
  fi

  proposal_file="$PM_STATE/proposals/${id}.json"
  if [[ -f "$proposal_file" ]] && jq -e . "$proposal_file" >/dev/null 2>&1; then
    proposal="$(cat "$proposal_file")"
  else
    proposal=null
  fi

  jq -c \
    --argjson p "$proposal" \
    '{document: ., proposal: $p, fetch_error: false}' \
    <<< "$doc" >> "$TMP/documents.jsonl"

  if (( count % 50 == 0 )); then
    echo "Bearbeitet: $count / $total"
  fi
done <<< "$ids"

echo "Erzeuge CSV-Bericht ..."

jq -s \
  --slurpfile tags "$TMP/tags.json" \
  --slurpfile correspondents "$TMP/correspondents.json" '
  def safe:
    tostring
    | gsub("ä";"ae") | gsub("ö";"oe") | gsub("ü";"ue")
    | gsub("Ä";"Ae") | gsub("Ö";"Oe") | gsub("Ü";"Ue")
    | gsub("ß";"ss")
    | gsub("&";"und")
    | gsub("[^A-Za-z0-9._-]+";"-")
    | gsub("-+";"-")
    | gsub("^[._-]+|[._-]+$";"");

  def tagname($id):
    ([$tags[0][] | select(.id == $id) | .name][0] // ("ID:" + ($id|tostring)));

  def correspondentname($id):
    if $id == null then ""
    elif ($id|type) == "string" then $id
    else ([$correspondents[0][] | select(.id == $id) | .name][0]
          // ("ID:" + ($id|tostring)))
    end;

  map(
    . as $item
    | ($item.document) as $d
    | ($item.proposal) as $p
    | ($p.proposal // {}) as $v
    | ($p.existing // {}) as $old
    | ($d.original_file_name // $old.original_file_name // "") as $original
    | ($d.archived_file_name // $old.archived_file_name // "") as $archived
    | (if $original != "" then $original else $archived end) as $source
    | (if ($source | contains("."))
       then ($source | capture("\\.(?<ext>[^.]+)$").ext)
       else "pdf" end) as $ext
    | ($v.document_date // "") as $rawdate
    | (if (($p.analysis.ocr_char_count // null) == 0)
          and $rawdate != ""
          and $rawdate == ($d.created // "")
       then ""
       else $rawdate end) as $date
    | (if ($date | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
       then ($date | gsub("-";"")) else "" end) as $datepart
    | (($v.primary_tag // "") | safe) as $category
    | (($v.correspondent // $v.correspondent_suggestion // "") | safe) as $corr
    | ([$datepart, $category] | map(select(length > 0)) | join("_")) as $prefix
    | ($d.id | tostring) as $id
    | (if $p == null then ""
       elif $corr != "" then
         ([$prefix, $corr] | map(select(length > 0)) | join("_")) + "." + $ext
       elif $source != "" then
         (if $prefix != "" then $prefix + "_" else "" end) + $source
       else
         (if $prefix != "" then $prefix else "Dokument_" + $id end)
           + "." + $ext
       end) as $filename
    | {
        id: $id,
        status: (
          if $item.fetch_error then "API-FEHLER"
          elif $p == null then "NOCH NICHT ANALYSIERT"
          else "VORSCHLAG VORHANDEN" end
        ),
        original: $source,
        category: ($v.primary_tag // ""),
        additional_tags: ($v.additional_tags // [] | join("; ")),
        current_tags: (
          ($d.tags // $old.tags // [])
          | map(if type == "number" then tagname(.) else tostring end)
          | join("; ")
        ),
        current_correspondent: correspondentname($d.correspondent // $old.correspondent),
        correspondent: ($v.correspondent // ""),
        correspondent_suggestion: ($v.correspondent_suggestion // ""),
        document_date: $date,
        confidence: (if $p == null then "" else ($v.confidence // "" | tostring) end),
        ocr_chars: (if $p == null or $p.analysis == null then "" else ($p.analysis.ocr_char_count // "" | tostring) end),
        requires_review: (if $p == null then "" else ($v.requires_review // false | tostring) end),
        filename: $filename,
        key: ($filename | ascii_downcase),
        validation: (($v.validation_warnings // []) | join("; ")),
        reason: ($v.reason // ""),
        review_note: (
          if $item.fetch_error then "Dokument konnte nicht aus der API gelesen werden"
          elif $p == null then "Analyse/Vorschlag fehlt"
          elif $p.analysis == null then "OCR-Analysewerte fehlen im gespeicherten Vorschlag"
          elif (($p.analysis.ocr_char_count // 0) < 100) then "OCR unter 100 Zeichen"
          elif (($v.confidence // 0) < 0.9) then "Konfidenz unter 0,9"
          elif ($v.primary_tag // "") == "" then "Hauptkategorie fehlt"
          elif ($v.requires_review // false) then "Manuelle Prüfung laut KI-Vorschlag"
          else "" end
        )
      }
  )
  | (reduce .[] as $r ({}; if $r.filename == "" then . else .[$r.key] = ((.[$r.key] // 0) + 1) end)) as $counts
  | map(
      . + {
        conflict: (
          if .filename != "" and $counts[.key] > 1
          then "KONFLIKT: gleicher vorgeschlagener Dateiname"
          else "" end
        )
      }
    )
  | ([
      "Dokument-ID",
      "Status",
      "Aktueller Dateiname",
      "Hauptkategorie (Tag)",
      "Zusätzliche Tags",
      "Aktuelle Tags",
      "Aktueller Korrespondent",
      "Korrespondent setzen",
      "Korrespondent-Vorschlag",
      "Dokumentdatum",
      "Konfidenz",
      "OCR-Zeichen",
      "Manuelle Prüfung",
      "Vorgeschlagener Dateiname",
      "Dateinamenskonflikt",
      "Validierungswarnungen",
      "Prüfhinweis",
      "KI-Begründung"
    ] | @csv),
    (.[] | [
      .id, .status, .original, .category, .additional_tags, .current_tags,
      .current_correspondent, .correspondent, .correspondent_suggestion,
      .document_date, .confidence, .ocr_chars, .requires_review, .filename,
      .conflict, .validation, .review_note, .reason
    ] | @csv)
  ' "$TMP/documents.jsonl" > "$REPORT"

echo
echo "Bericht erstellt: $REPORT"
echo "Dokumente gefunden: $total"
echo "CSV-Zeilen einschließlich Kopfzeile: $(wc -l < "$REPORT")"
echo "API-Fehler: $(wc -l < "$TMP/errors.txt")"
echo "Keine Metadaten oder Dateien wurden verändert."
