#!/usr/bin/env bash
set -uo pipefail

BASE_DIR="/home/pi/docker/paperless/paperless_metadata"
REPORT="$BASE_DIR/state/reports/korrespondenten_uebernahme_20261010_141018.json"
OUT="$BASE_DIR/state/reports/korrespondenten_kontrolle.json"
API_BASE="${PAPERLESS_URL:-http://rasp2:1888}"
API_BASE="${API_BASE%/}/api/"

if [[ -z "${PAPERLESS_TOKEN:-}" ]]; then
    echo "FEHLER: PAPERLESS_TOKEN ist nicht gesetzt." >&2
    exit 1
fi

if [[ ! -f "$REPORT" ]]; then
    echo "FEHLER: Übernahmebericht nicht gefunden: $REPORT" >&2
    exit 1
fi

command -v curl >/dev/null || { echo "FEHLER: curl fehlt."; exit 1; }
command -v jq >/dev/null || { echo "FEHLER: jq fehlt."; exit 1; }

tmp_results=$(mktemp)
trap 'rm -f "$tmp_results"' EXIT

total=0
ok=0
missing=0
mismatch=0
errors=0

while IFS=$'\t' read -r id title expected_id expected_name; do
    [[ -n "$id" ]] || continue
    total=$((total + 1))

    response=$(curl -sS --connect-timeout 10 --max-time 30 \
        -H "Authorization: Token $PAPERLESS_TOKEN" \
        -H "Accept: application/json" \
        -w $'\n%{http_code}' \
        "${API_BASE}documents/${id}/") || {
            status="ERROR"
            errors=$((errors + 1))
            jq -cn --argjson id "$id" --arg title "$title" \
                --arg name "$expected_name" --arg status "$status" \
                '{document_id:$id,title:$title,expected_correspondent:$name,status:$status}' \
                >> "$tmp_results"
            continue
        }

    http_code="${response##*$'\n'}"
    body="${response%$'\n'*}"

    if [[ "$http_code" != "200" ]]; then
        status="ERROR"
        errors=$((errors + 1))
        jq -cn --argjson id "$id" --arg title "$title" \
            --arg name "$expected_name" --arg status "$status" \
            --arg http "$http_code" \
            '{document_id:$id,title:$title,expected_correspondent:$name,status:$status,http_status:$http}' \
            >> "$tmp_results"
        continue
    fi

    actual_id=$(jq -r '.correspondent // "null"' <<< "$body")

    if [[ "$actual_id" == "$expected_id" ]]; then
        status="OK"
        ok=$((ok + 1))
    elif [[ "$actual_id" == "null" ]]; then
        status="MISSING"
        missing=$((missing + 1))
    else
        status="MISMATCH"
        mismatch=$((mismatch + 1))
    fi

    jq -cn \
        --argjson id "$id" \
        --arg title "$title" \
        --arg name "$expected_name" \
        --argjson expected_id "$expected_id" \
        --arg actual_id "$actual_id" \
        --arg status "$status" \
        '{document_id:$id,title:$title,expected_correspondent:$name,expected_id:$expected_id,actual_correspondent_id:($actual_id|if .=="null" then null else tonumber end),status:$status}' \
        >> "$tmp_results"

    if (( total % 50 == 0 )); then
        echo "Kontrolliert: $total"
    fi
done < <(
    jq -r '
      .results[]
      | select(.status == "ASSIGNED" or .status == "ALREADY_CORRECT")
      | [
          .document_id,
          (.title // "" | gsub("[\t\r\n]"; " ")),
          .correspondent_id,
          (.name // "")
        ]
      | @tsv
    ' "$REPORT"
)

jq -s 
    --argjson total "$total" 
    --argjson ok "$ok" 
    --argjson missing "$missing" 
    --argjson mismatch "$mismatch" 
    --argjson errors "$errors" 
    '{
       documents_checked:$total,
       status_counts:{
         OK:$ok,
         MISSING:$missing,
         MISMATCH:$mismatch,
         ERROR:$errors
       },
       results:.
     }' "$tmp_results" > "$OUT"

echo
echo "=== Kontrolle der Korrespondentenzuordnungen ==="
echo "Geprüfte Dokumente:       $total"
echo "Korrekt gespeichert:      $ok"
echo "Korrespondent fehlt:      $missing"
echo "Abweichende Zuordnung:    $mismatch"
echo "API-/Lesefehler:          $errors"
echo "Kontrollbericht: $OUT"

if (( missing + mismatch + errors > 0 )); then
    echo
    echo "=== Prüffälle ==="
    jq -r '
      .results[]
      | select(.status != "OK")
      | "ID \(.document_id) | \(.status) | \(.title // "")"
    ' "$OUT"
fi
