#!/usr/bin/env bash
# Manuelles Anwenden von Gemini-Proposals auf Paperless.
#
# Standard: Dry-Run
# --apply:   Änderungen tatsächlich übernehmen
# --id ID:   genau ein Dokument bearbeiten
# --limit N: Anzahl der Proposals im Batch-Modus begrenzen
#
# Unterschiede zu 03_apply_proposals.sh:
# - keine Review-Sperren
# - bereits angewendete Proposals dürfen erneut angewendet werden
# - nicht leerer Gemini-Titel wird immer gesetzt
# - keine Google-Drive-Aktionen

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/paperless_api.sh"
pm_init

MODE="dry-run"
ONLY_ID=""
LIMIT=0

usage() {
    echo "Aufruf: $0 [--id NUMMER] [--limit ANZAHL] [--apply]"
}

while (($#)); do
    case "$1" in
        --apply)
            MODE="apply"
            ;;
        --id)
            [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || {
                echo "FEHLER: --id benötigt eine numerische Dokument-ID." >&2
                exit 2
            }
            ONLY_ID="$2"
            shift
            ;;
        --limit)
            [[ $# -ge 2 && "$2" =~ ^[0-9]+$ && "$2" -gt 0 ]] || {
                echo "FEHLER: --limit benötigt eine positive Zahl." >&2
                exit 2
            }
            LIMIT="$2"
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "FEHLER: Unbekannter Parameter: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

: "${PAPERLESS_TOKEN:?PAPERLESS_TOKEN fehlt}"
: "${PAPERLESS_URL:?PAPERLESS_URL fehlt}"

PROPOSALS="$PM_STATE/proposals"
BACKUPS="$PM_STATE/applied_backups"

[[ -d "$PROPOSALS" ]] || {
    echo "FEHLER: Proposal-Verzeichnis nicht gefunden: $PROPOSALS" >&2
    exit 1
}

mkdir -p "$BACKUPS"

# Entspricht dem bewährten API-Muster aus 03_apply_proposals.sh.
api_write() {
    local method="$1" endpoint="$2" payload="$3"
    local response code

    response="$(mktemp)"

    if ! code="$(curl --silent --show-error \
        --connect-timeout 10 --max-time 120 \
        -X "$method" \
        -H "Authorization: Token ${PAPERLESS_TOKEN}" \
        -H "Accept: application/json; version=${PAPERLESS_API_VERSION}" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        -o "$response" -w '%{http_code}' \
        "${PAPERLESS_URL%/}${endpoint}")"; then
        cat "$response" >&2
        rm -f "$response"
        return 1
    fi

    if [[ "$code" != 200 && "$code" != 201 && "$code" != 202 ]]; then
        echo "API-Fehler HTTP $code bei $method $endpoint" >&2
        cat "$response" >&2
        rm -f "$response"
        return 1
    fi

    cat "$response"
    rm -f "$response"
}

# Direkt aus dem funktionierenden Muster von 03_apply_proposals.sh.
find_id_by_name() {
    local catalog="$1" name="$2"

    # Katalog zuerst validieren. Bei fehlerhafter API-Ausgabe
    # nicht so tun, als existiere der Eintrag nicht.
    if ! jq -e 'type == "array"' <<< "$catalog" >/dev/null; then
        echo "FEHLER: Paperless-Katalog ist kein gültiges JSON-Array." >&2
        return 1
    fi

    # Bewusst eine einzige physische Zeile: keine Backslash-Fortsetzung.
    jq -r --arg name "$name" '[.[] | select(.name == $name) | .id][0] // empty' <<< "$catalog"
}
ensure_resource() {
    local resource="$1" name="$2"
    local catalog id payload

    catalog="$(pm_paperless_catalog "$resource")"
    id="$(find_id_by_name "$catalog" "$name")"

    if [[ -n "$id" ]]; then
        printf '%s\n' "$id"
        return 0
    fi

    if [[ "$MODE" == "dry-run" ]]; then
        printf 'WOULD_CREATE:%s:%s\n' "$resource" "$name"
        return 0
    fi

    payload="$(jq -nc --arg name "$name" '{name:$name}')"
    api_write POST "/api/${resource}/" "$payload" >/dev/null

    catalog="$(pm_paperless_catalog "$resource")"
    id="$(find_id_by_name "$catalog" "$name")"

    [[ -n "$id" ]] || {
        echo "Eintrag nach Erstellung nicht gefunden: $resource / $name" >&2
        return 1
    }

    printf '%s\n' "$id"
}

count_processed=0
count_skipped=0
count_failed=0

shopt -s nullglob

if [[ -n "$ONLY_ID" ]]; then
    files=("$PROPOSALS/$ONLY_ID.json")
    [[ -f "${files[0]}" ]] || {
        echo "Proposal für Dokument $ONLY_ID nicht gefunden: ${files[0]}" >&2
        exit 1
    }
else
    files=()
    for candidate in "$PROPOSALS"/*.json; do
        # Absichtlich kein Filter auf .applied.
        files+=("$candidate")
        if (( LIMIT > 0 && ${#files[@]} >= LIMIT )); then
            break
        fi
    done
fi

total=${#files[@]}

echo "[INFO] $total ausgewählte Proposal-Dateien."
echo "[INFO] Modus: $MODE"
echo "[INFO] Bereits angewendete Proposals dürfen erneut angewendet werden."

for file in "${files[@]}"; do
    echo
    echo "[INFO] Proposal: $(basename "$file")"

    if ! jq -e \
        '(.document_id | type == "number") and (.proposal | type == "object")' \
        "$file" >/dev/null 2>&1; then
        echo "[SKIP] Ungültige Proposal-Datei: $file" >&2
        count_skipped=$((count_skipped + 1))
        continue
    fi

    # .applied wird bewusst nicht als Ausschlusskriterium verwendet.
    id="$(jq -r '.document_id' "$file")"
    primary="$(jq -r '.proposal.primary_tag // empty' "$file")"
    doc_date="$(jq -r '.proposal.document_date // empty' "$file")"
    title="$(jq -r '.proposal.title // empty' "$file")"
    correspondent="$(jq -r \
        '.proposal.correspondent // .proposal.correspondent_suggestion // empty' \
        "$file")"

    if [[ -z "$primary" ]]; then
        echo "[SKIP] Dokument $id: keine Hauptkategorie." >&2
        count_skipped=$((count_skipped + 1))
        continue
    fi

    if [[ -n "$doc_date" ]]; then
        if [[ ! "$doc_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] ||
            ! date -d "$doc_date" '+%F' >/dev/null 2>&1 ||
            [[ "$(date -d "$doc_date" '+%F')" != "$doc_date" ]]; then
            echo "[SKIP] Dokument $id: ungültiges Datum '$doc_date'." >&2
            count_skipped=$((count_skipped + 1))
            continue
        fi
    fi

    echo "[INFO] Dokument $id: Paperless-Daten werden gelesen."

    if ! doc="$(pm_paperless_document "$id")"; then
        echo "[FEHLER] Dokument $id kann nicht gelesen werden." >&2
        count_failed=$((count_failed + 1))
        continue
    fi

    existing_tags="$(jq -c '[.tags[]?]' <<< "$doc")"

    if ! tag_names="$(jq -er '
        ([.proposal.primary_tag] + (.proposal.additional_tags // []))
        | if all(.[]; type == "string")
          then map(select(length > 0)) | unique | .[]
          else error("Tags müssen Strings sein")
          end
    ' "$file")"; then
        echo "[FEHLER] Dokument $id: Tags sind ungültig." >&2
        count_failed=$((count_failed + 1))
        continue
    fi

    new_ids=()
    failed=false

    while IFS= read -r name; do
        [[ -n "$name" ]] || continue

        echo "[INFO] Dokument $id: Tag wird geprüft: $name"

        if ! result="$(ensure_resource tags "$name")"; then
            failed=true
            break
        fi

        if [[ "$result" == WOULD_CREATE:* ]]; then
            echo "[DRY-RUN] Tag würde angelegt: $name"
            continue
        fi

        new_ids+=("$result")
    done <<< "$tag_names"

    if [[ "$failed" == true ]]; then
        echo "[FEHLER] Dokument $id: Tags konnten nicht vorbereitet werden." >&2
        count_failed=$((count_failed + 1))
        continue
    fi

    corr_id=""

    if [[ -n "$correspondent" ]]; then
        echo "[INFO] Dokument $id: Korrespondent wird geprüft: $correspondent"

        if ! corr_id="$(ensure_resource correspondents "$correspondent")"; then
            echo "[FEHLER] Dokument $id: Korrespondent nicht verfügbar." >&2
            count_failed=$((count_failed + 1))
            continue
        fi

        if [[ "$corr_id" == WOULD_CREATE:* ]]; then
            echo "[DRY-RUN] Korrespondent würde angelegt: $correspondent"
            corr_id=""
        fi
    fi

    if [[ "$MODE" == "dry-run" ]]; then
        echo "[DRY-RUN] Dokument $id: Hauptkategorie=$primary"
        echo "[DRY-RUN] Dokument $id: Datum=${doc_date:-unverändert}"
        echo "[DRY-RUN] Dokument $id: Korrespondent=${correspondent:-unverändert}"
        echo "[DRY-RUN] Dokument $id: Titel=${title:-unverändert}"
        echo "[DRY-RUN] Dokument $id: vorhandene Tags bleiben erhalten"
        echo "[DRY-RUN] Dokument $id: Proposal-Status bleibt unverändert"
        count_processed=$((count_processed + 1))
        continue
    fi

    new_ids_json="$(printf '%s\n' "${new_ids[@]}" | jq -Rsc \
        'split("\n") | map(select(length > 0) | tonumber)')"

    all_tags="$(jq -cn \
        --argjson old "$existing_tags" \
        --argjson new "$new_ids_json" \
        '$old + $new | unique')"

    if ! jq -e \
        'type == "array" and all(.[]; type == "number")' \
        <<< "$all_tags" >/dev/null; then
        echo "[FEHLER] Dokument $id: ungültiges Tag-Array." >&2
        count_failed=$((count_failed + 1))
        continue
    fi

    # Ein nicht leerer Gemini-Titel wird immer gesetzt,
    # auch wenn Paperless bereits einen Titel enthält.
    patch="$(jq -nc \
        --argjson tags "$all_tags" \
        --arg date "$doc_date" \
        --arg title "$title" \
        --arg corr "$corr_id" '
        {tags:$tags}
        + (if $date != "" then {created:$date} else {} end)
        + (if $corr != "" then {correspondent:($corr|tonumber)} else {} end)
        + (if $title != "" then {title:$title} else {} end)
    ')"

    # Zeitgestempelte Sicherung, damit frühere Sicherungen erhalten bleiben.
    backup="$BACKUPS/$(basename "$file").$(date +%Y%m%d_%H%M%S).bak"
    cp -p "$file" "$backup"
    echo "[INFO] Proposal-Sicherung: $backup"

    echo "[INFO] Dokument $id: Änderungen werden an Paperless gesendet."

    if ! api_write PATCH "/api/documents/$id/" "$patch" >/dev/null; then
        echo "[FEHLER] Dokument $id: PATCH fehlgeschlagen." >&2
        count_failed=$((count_failed + 1))
        continue
    fi

    if ! verified="$(pm_paperless_document "$id")"; then
        echo "[FEHLER] Dokument $id: Rückprüfung fehlgeschlagen." >&2
        count_failed=$((count_failed + 1))
        continue
    fi

    if ! jq -e --argjson expected "$all_tags" \
        '([.tags[]?] | sort) == ($expected | sort)' \
        <<< "$verified" >/dev/null; then
        echo "[FEHLER] Dokument $id: Tags stimmen nach PATCH nicht überein." >&2
        count_failed=$((count_failed + 1))
        continue
    fi

    if [[ -n "$doc_date" ]] &&
        [[ "$(jq -r '.created // empty' <<< "$verified")" != "$doc_date" ]]; then
        echo "[FEHLER] Dokument $id: Datum nicht bestätigt." >&2
        count_failed=$((count_failed + 1))
        continue
    fi

    if [[ -n "$corr_id" ]] &&
        [[ "$(jq -r '.correspondent // empty' <<< "$verified")" != "$corr_id" ]]; then
        echo "[FEHLER] Dokument $id: Korrespondent nicht bestätigt." >&2
        count_failed=$((count_failed + 1))
        continue
    fi

    if [[ -n "$title" ]] &&
        [[ "$(jq -r '.title // empty' <<< "$verified")" != "$title" ]]; then
        echo "[FEHLER] Dokument $id: Titel nicht bestätigt." >&2
        count_failed=$((count_failed + 1))
        continue
    fi

    tmp="$(mktemp "${file}.tmp.XXXXXX")"

    if ! jq '.applied = true | .applied_at = (now | todate)' "$file" > "$tmp"; then
        rm -f "$tmp"
        echo "[FEHLER] Dokument $id: Proposal-Status konnte nicht aktualisiert werden." >&2
        count_failed=$((count_failed + 1))
        continue
    fi

    mv "$tmp" "$file"

    echo "[OK] Dokument $id: Gemini-Daten übernommen."
    count_processed=$((count_processed + 1))
done

echo
echo "Modus:        $MODE"
echo "Verarbeitet:  $count_processed"
echo "Übersprungen: $count_skipped"
echo "Fehler:       $count_failed"

if (( count_failed > 0 )); then
    exit 1
fi
