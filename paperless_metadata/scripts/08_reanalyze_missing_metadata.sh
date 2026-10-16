#!/usr/bin/env bash
# Read-only-Nachanalyse fehlender Metadaten.
# Paperless-Dokumente und bestehende Vorschlaege bleiben unveraendert.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib/paperless_api.sh"
source "$ROOT/scripts/lib/llm_api.sh"

LIMIT="${1:-3}"

if [[ ! "$LIMIT" =~ ^[1-9][0-9]*$ ]]; then
    echo "Aufruf: $0 [ANZAHL]" >&2
    exit 2
fi

pm_init

if [[ -z "${PAPERLESS_TOKEN:-}" || -z "${GEMINI_API_KEY:-}" ]]; then
    echo "PAPERLESS_TOKEN und GEMINI_API_KEY muessen gesetzt sein." >&2
    exit 2
fi

if (( LIMIT > LLM_MAX_REQUESTS_PER_RUN )); then
    echo "Limit zu hoch. Maximal: $LLM_MAX_REQUESTS_PER_RUN" >&2
    exit 2
fi

PROPOSALS="$PM_STATE/proposals"
OUT="$PM_STATE/reanalysis"

mkdir -p "$OUT"

[[ -d "$PROPOSALS" ]] || {
    echo "Vorschlagsverzeichnis fehlt: $PROPOSALS" >&2
    exit 1
}

[[ -f "$ROOT/config/tag_catalog.json" ]] || {
    echo "Tag-Katalog fehlt." >&2
    exit 1
}

exec 9>"$PM_STATE/.reanalysis.lock"
flock -n 9 || {
    echo "Eine Nachanalyse laeuft bereits." >&2
    exit 1
}

# Paperless-Kataloge ausschliesslich lesend aktualisieren.
for resource in tags correspondents document_types; do
    if ! pm_paperless_catalog "$resource" |
        pm_atomic_json "$PM_STATE/analysis/${resource}.json"; then
        echo "Katalog konnte nicht gelesen werden: $resource" >&2
        exit 1
    fi
done

processed=0
failed=0
selected=0

echo "=== Paperless-Metadaten-Nachanalyse (DRY-RUN) ==="
echo "Limit: $LIMIT"
echo "Ausgabe: $OUT"
echo "Bestehende Vorschlaege werden nicht ueberschrieben."
echo

while IFS= read -r -d '' file; do
    [[ -f "$file" ]] || continue
    jq -e . "$file" >/dev/null 2>&1 || continue

    id="$(jq -r '.document_id // empty' "$file")"
    [[ "$id" =~ ^[0-9]+$ ]] || continue

    # Nur vorhandene Vorschlaege mit fehlendem Korrespondenten
    # oder fehlendem Dokumentdatum bearbeiten.
    if ! jq -e '
        (.proposal.correspondent == null or
         (.proposal.correspondent | strings | gsub("^\\s+|\\s+$"; "") == ""))
        or
        (.proposal.document_date == null or
         (.proposal.document_date | strings | gsub("^\\s+|\\s+$"; "") == ""))
    ' "$file" >/dev/null; then
        continue
    fi

    # Vorhandene Nachanalyse-Ergebnisse nicht ueberschreiben.
    [[ -e "$OUT/$id.json" ]] && continue

    selected=$((selected + 1))
    echo "Analysiere Dokument $id ..."

    docfile="$(mktemp)"
    reqfile="$(mktemp)"
    propfile="$(mktemp)"
    resultfile="$(mktemp)"
    tmpout="$OUT/$id.json.tmp"

    cleanup() {
        rm -f "$docfile" "$reqfile" "$propfile" "$resultfile"
    }

    if ! pm_paperless_document "$id" > "$docfile"; then
        echo "FEHLER: Dokument $id konnte nicht gelesen werden."
        failed=$((failed + 1))
        cleanup
        (( selected >= LIMIT )) && break
        continue
    fi

    if ! jq -n \
        --slurpfile doc "$docfile" \
        --slurpfile tags "$PM_STATE/analysis/tags.json" \
        --slurpfile correspondents "$PM_STATE/analysis/correspondents.json" \
        --slurpfile types "$PM_STATE/analysis/document_types.json" \
        --slurpfile catalog "$ROOT/config/tag_catalog.json" \
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
        }' > "$reqfile"; then
        echo "FEHLER: Anfrage fuer Dokument $id konnte nicht erstellt werden."
        failed=$((failed + 1))
        cleanup
        (( selected >= LIMIT )) && break
        continue
    fi

    if ! pm_llm_classify "$(cat "$reqfile")" > "$propfile"; then
        echo "FEHLER: Gemini-Aufruf fuer Dokument $id fehlgeschlagen."
        failed=$((failed + 1))
        cleanup
        (( selected >= LIMIT )) && break
        continue
    fi

    if ! jq -e '
        (.primary_tag | type == "string") and
        (.additional_tags | type == "array") and
        (.correspondent == null or (.correspondent | type == "string")) and
        (.correspondent_suggestion == null or (.correspondent_suggestion | type == "string")) and
        (.document_date == null or (.document_date | type == "string")) and
        (.confidence | type == "number" and . >= 0 and . <= 1) and
        (.requires_review | type == "boolean") and
        (.reason | type == "string")
    ' "$propfile" >/dev/null 2>&1; then
        echo "FEHLER: Ungueltige KI-Antwort fuer Dokument $id."
        failed=$((failed + 1))
        cleanup
        (( selected >= LIMIT )) && break
        continue
    fi

    # Ohne OCR-Text das Importdatum nicht als Dokumentdatum uebernehmen.
    if ! jq \
        --slurpfile req "$reqfile" \
        --slurpfile doc "$docfile" \
        '($req[0]) as $request
         | ($doc[0]) as $document
         | if (($request.document.content // "") | length) == 0
              and .document_date != null
              and .document_date == ($document.created // "")
           then .document_date = null
           else .
           end' "$propfile" > "$resultfile"; then
        echo "FEHLER: Antwort fuer Dokument $id konnte nicht geprueft werden."
        failed=$((failed + 1))
        cleanup
        (( selected >= LIMIT )) && break
        continue
    fi

    # Ergebnis mit Altvorschlag getrennt ablegen.
    # Original unter state/proposals bleibt unveraendert.
    if ! jq -n \
        --slurpfile old "$file" \
        --slurpfile doc "$docfile" \
        --slurpfile req "$reqfile" \
        --slurpfile new "$resultfile" \
        --arg provider "$LLM_PROVIDER" \
        --arg model "$GEMINI_MODEL" \
        --arg generated "$(date -Is)" \
        '($old[0]) as $old
         | ($doc[0]) as $doc
         | ($req[0]) as $req
         | ($new[0]) as $new
         | {
             document_id: $doc.id,
             title: $doc.title,
             original_file_name: $doc.original_file_name,
             ocr_char_count: (($doc.content // "") | length),
             ocr_sent_char_count: (($req.document.content // "") | length),
             missing_before: {
                 correspondent: ($old.proposal.correspondent == null or
                     $old.proposal.correspondent == ""),
                 document_date: ($old.proposal.document_date == null or
                     $old.proposal.document_date == "")
             },
             previous_proposal: $old.proposal,
             reanalysis_proposal: $new,
             remaining_missing: {
                 correspondent: ($new.correspondent == null or
                     $new.correspondent == ""),
                 document_date: ($new.document_date == null or
                     $new.document_date == "")
             },
             provider: $provider,
             model: $model,
             generated_at: $generated,
             applied: false
         }' > "$tmpout"; then
        echo "FEHLER: Ergebnisdatei fuer Dokument $id konnte nicht erstellt werden."
        failed=$((failed + 1))
        rm -f "$tmpout"
        cleanup
        (( selected >= LIMIT )) && break
        continue
    fi

    # JSON vor der atomaren Ablage pruefen.
    if ! jq -e . "$tmpout" >/dev/null 2>&1; then
        echo "FEHLER: Ergebnisdatei fuer Dokument $id ist ungueltig."
        failed=$((failed + 1))
        rm -f "$tmpout"
        cleanup
        (( selected >= LIMIT )) && break
        continue
    fi

    mv "$tmpout" "$OUT/$id.json"
    processed=$((processed + 1))

    jq -r '
        "  Alt: Korrespondent=" +
        ((.previous_proposal.correspondent // "FEHLT") | tostring) +
        ", Datum=" +
        ((.previous_proposal.document_date // "FEHLT") | tostring) +
        "\n  Neu: Korrespondent=" +
        ((.reanalysis_proposal.correspondent // "FEHLT") | tostring) +
        ", Datum=" +
        ((.reanalysis_proposal.document_date // "FEHLT") | tostring) +
        "\n  OCR-Zeichen: " + (.ocr_char_count | tostring)
    ' "$OUT/$id.json"

    cleanup
    (( selected >= LIMIT )) && break
done < <(find "$PROPOSALS" -maxdepth 1 -type f -name '*.json' -print0 | sort -z)

echo
echo "=== Ergebnis ==="
echo "Ausgewaehlt: $selected"
echo "Erfolgreich nachanalysiert: $processed"
echo "Fehler: $failed"
echo "Ergebnisse: $OUT"
echo "Paperless-Dokumente veraendert: NEIN"
echo "Urspruengliche Vorschlaege ueberschrieben: NEIN"

(( failed == 0 ))
