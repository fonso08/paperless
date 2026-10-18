#!/usr/bin/env bash
# Übernimmt freigegebene Gemini-Vorschläge in Paperless.
# Standard: Dry-Run. Schreiben nur mit --apply.
set -euo pipefail

source "$(dirname "$0")/lib/paperless_api.sh"
pm_init

MODE="dry-run"
ONLY_ID=""
LIMIT=0

while (($#)); do
  case "$1" in
    --apply) MODE="apply" ;;
    --id)
      [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || {
        echo "Aufruf: $0 [--id NUMMER] [--limit ANZAHL] [--apply]" >&2
        exit 2
      }
      ONLY_ID="$2"
      shift
      ;;
    --limit)
      [[ $# -ge 2 && "$2" =~ ^[0-9]+$ && "$2" -gt 0 ]] || {
        echo "--limit benötigt eine positive Zahl." >&2
        exit 2
      }
      LIMIT="$2"
      shift
      ;;
    *)
      echo "Aufruf: $0 [--id NUMMER] [--limit ANZAHL] [--apply]" >&2
      exit 2
      ;;
  esac
  shift
done

: "${PAPERLESS_TOKEN:?PAPERLESS_TOKEN fehlt}"
: "${PAPERLESS_URL:?PAPERLESS_URL fehlt}"

PROPOSALS="$PM_STATE/proposals"
BACKUPS="$PM_STATE/applied_backups"
mkdir -p "$BACKUPS"

api_write() {
  local method="$1" endpoint="$2" payload="$3" response code
  response="$(mktemp)"
  code="$(curl --silent --show-error \
    --connect-timeout 10 --max-time 120 \
    -X "$method" \
    -H "Authorization: Token ${PAPERLESS_TOKEN}" \
    -H "Accept: application/json; version=${PAPERLESS_API_VERSION}" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    -o "$response" -w '%{http_code}' \
    "${PAPERLESS_URL%/}${endpoint}")" || {
      cat "$response" >&2
      rm -f "$response"
      return 1
    }

  if [[ "$code" != 200 && "$code" != 201 && "$code" != 202 ]]; then
    echo "API-Fehler HTTP $code bei $method $endpoint" >&2
    cat "$response" >&2
    rm -f "$response"
    return 1
  fi

  cat "$response"
  rm -f "$response"
}

get_catalog() {
  pm_paperless_catalog "$1"
}

find_id_by_name() {
  jq -r --arg name "$2" \
    '[.[] | select(.name == $name) | .id][0] // empty' <<< "$1"
}

ensure_resource() {
  local resource="$1" name="$2" catalog id payload
  catalog="$(get_catalog "$resource")"
  id="$(find_id_by_name "$catalog" "$name")"
  if [[ -n "$id" ]]; then
    printf '%s\n' "$id"
    return 0
  fi

  if [[ "$MODE" == "dry-run" ]]; then
    echo "WOULD_CREATE:$resource:$name"
    return 0
  fi

  payload="$(jq -nc --arg name "$name" '{name:$name}')"
  api_write POST "/api/${resource}/" "$payload" >/dev/null

  catalog="$(get_catalog "$resource")"
  id="$(find_id_by_name "$catalog" "$name")"
  [[ -n "$id" ]] || {
    echo "Neu angelegter Eintrag nicht auffindbar: $resource / $name" >&2
    return 1
  }
  printf '%s\n' "$id"
}

count_applied=0
count_skipped=0
count_review=0
count_failed=0

shopt -s nullglob
shopt -s nullglob

if [[ -n "$ONLY_ID" ]]; then
  files=("$PROPOSALS/$ONLY_ID.json")
  [[ -f "${files[0]}" ]] || {
    echo "Proposal für Dokument $ONLY_ID nicht gefunden." >&2
    exit 1
  }
else
  files=()
  for candidate in "$PROPOSALS"/*.json; do
    jq -e '
      .applied != true and
      .proposal.requires_review == false and
      .proposal.review_decision == "no_check_needed" and
      (.proposal.confidence | type == "number" and . >= 0.85) and
      ((.proposal.validation_warnings // []) | length == 0)
    ' "$candidate" >/dev/null 2>&1 || continue

    files+=("$candidate")
    if (( LIMIT > 0 && ${#files[@]} >= LIMIT )); then
      break
    fi
  done
fi

total=${#files[@]}
seen=0
echo "[INFO] $total ausgewählte Proposal-Dateien."

for file in "${files[@]}"; do
  ((seen+=1))
  if (( seen == 1 || seen % 25 == 0 )); then
    echo "[FORTSCHRITT] $seen/$total: $(basename "$file")"
  fi
  jq -e '(.document_id | numbers) and (.proposal | type == "object")' \
    "$file" >/dev/null 2>&1 || continue

  if [[ "$(jq -r '.applied // false' "$file")" == "true" ]]; then
    ((count_skipped+=1))
    continue
  fi

  if [[ "$(jq -r '.proposal.requires_review == true' "$file")" != "false" ]]; then
    ((count_review+=1))
    continue
  fi

  id="$(jq -r '.document_id' "$file")"
  [[ -z "$ONLY_ID" || "$id" == "$ONLY_ID" ]] || continue

  decision="$(jq -r '.proposal.review_decision // "unset"' "$file")"
  if [[ "$decision" != "no_check_needed" ]]; then
    echo "[SKIP] Dokument $id: review_decision=$decision"
    ((count_review+=1))
    continue
  fi

  if ! jq -e '(.proposal.confidence | type == "number" and . >= 0.85)' "$file" >/dev/null 2>&1; then
    echo "[SKIP] Dokument $id: Konfidenz fehlt oder liegt unter 0.85"
    ((count_review+=1))
    continue
  fi
  warnings="$(jq -r '(.proposal.validation_warnings // []) | length' "$file")"
  if [[ "$warnings" != "0" ]]; then
    echo "[SKIP] Dokument $id: Validierungswarnungen vorhanden"
    ((count_review+=1))
    continue
  fi

  primary="$(jq -r '.proposal.primary_tag // empty' "$file")"
  date="$(jq -r '.proposal.document_date // empty' "$file")"
  title="$(jq -r '.proposal.title // empty' "$file")"
  manual_approved="$(jq -r '.manual_review.approved_at // empty' "$file")"
  correspondent="$(jq -r '.proposal.correspondent // .proposal.correspondent_suggestion // empty' "$file")"

  [[ -n "$primary" ]] || {
    echo "[SKIP] Dokument $id: keine Hauptkategorie"
    ((count_skipped+=1))
    continue
  }

  if [[ -n "$date" && ! "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    echo "[SKIP] Dokument $id: ungültiges Datum '$date'"
    ((count_skipped+=1))
    continue
  fi

  if ! doc="$(pm_paperless_document "$id")"; then
    echo "[FEHLER] Dokument $id kann nicht gelesen werden" >&2
    ((count_failed+=1))
    continue
  fi

  existing_tags="$(jq -c '[.tags[]?]' <<< "$doc")"
  tag_names="$(jq -r \
    '([.proposal.primary_tag] + (.proposal.additional_tags // []))
     | map(select(type == "string" and length > 0)) | unique[]' "$file")"

  new_ids=()
  failed=false
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    result="$(ensure_resource tags "$name")" || { failed=true; break; }
    if [[ "$result" == WOULD_CREATE:* ]]; then
      echo "[DRY-RUN] Dokument $id: Tag anlegen: $name"
      continue
    fi
    new_ids+=("$result")
  done <<< "$tag_names"

  if [[ "$failed" == true ]]; then
    echo "[FEHLER] Dokument $id: Tags konnten nicht vorbereitet werden" >&2
    ((count_failed+=1))
    continue
  fi

  corr_id=""
  if [[ -n "$correspondent" ]]; then
    current_corr="$(jq -r '.correspondent // empty' <<< "$doc")"
    manual_approved="$(jq -r '.manual_review.approved_at // empty' "$file")"
    # Eine ausdrueckliche Review-Freigabe darf auch einen bereits gesetzten
    # Korrespondenten korrigieren. Ohne manuelle Freigabe bleibt das alte
    # konservative Verhalten erhalten.
    if [[ -n "$current_corr" && -z "$manual_approved" ]]; then
      corr_id="$current_corr"
    else
      corr_id="$(ensure_resource correspondents "$correspondent")" || {
        echo "[FEHLER] Dokument $id: Korrespondent nicht verfügbar" >&2
        ((count_failed+=1))
        continue
      }
      if [[ "$corr_id" == WOULD_CREATE:* ]]; then
        echo "[DRY-RUN] Dokument $id: Korrespondent anlegen: $correspondent"
        corr_id=""
      fi
    fi
  fi

  # Bestehende Tags behalten und neue IDs ergänzen.
  if [[ "$MODE" == "apply" ]]; then
    new_ids_json="$(printf '%s\n' "${new_ids[@]}" | jq -Rsc '
      split("\n") | map(select(length > 0) | tonumber)
    ')"
    all_tags="$(jq -cn \
      --argjson old "$existing_tags" \
      --argjson new "$new_ids_json" \
      '$old + $new | unique')"

    # Sicherheitsprüfung: Paperless muss eine Liste numerischer IDs erhalten.
    jq -e 'type == "array" and all(.[]; type == "number")' \
      <<< "$all_tags" >/dev/null || {
        echo "[FEHLER] Ungültiges Tag-Array: $all_tags" >&2
        exit 1
      }

    doc_tmp="$(mktemp)"
    printf '%s\n' "$doc" > "$doc_tmp"

    if ! patch="$(jq -nc \
      --argjson tags "$all_tags" \
      --arg date "$date" \
      --arg title "$title" \
      --arg corr "$corr_id" \
      --arg manual_approved "$manual_approved" \
      --slurpfile olddoc "$doc_tmp" '
        {tags:$tags}
        + (if $date != "" then {created:$date} else {} end)
        + (if $corr != "" and ($olddoc[0].correspondent == null or $manual_approved != "")
           then {correspondent:($corr|tonumber)} else {} end)
        + (if $title != "" and $manual_approved != "" then {title:$title} else {} end)
      ')"; then
      rm -f "$doc_tmp"
      echo "[FEHLER] Dokument $id: PATCH konnte nicht erstellt werden." >&2
      ((count_failed+=1))
      continue
    fi
    rm -f "$doc_tmp"

    cp -p "$file" "$BACKUPS/$(basename "$file").bak"
    api_write PATCH "/api/documents/$id/" "$patch" >/dev/null

    # Werte zurücklesen und erst dann applied=true setzen.
    verified="$(pm_paperless_document "$id")" || {
      echo "[FEHLER] Dokument $id: Rückprüfung fehlgeschlagen" >&2
      ((count_failed+=1))
      continue
    }

    if ! jq -e --argjson expected "$all_tags" \
      '([.tags[]?] | sort) == ($expected | sort)' \
      <<< "$verified" >/dev/null; then
      echo "[FEHLER] Dokument $id: Tags stimmen nach PATCH nicht überein" >&2
      ((count_failed+=1))
      continue
    fi

    if [[ -n "$date" ]] &&
       [[ "$(jq -r '.created' <<< "$verified")" != "$date" ]]; then
      echo "[FEHLER] Dokument $id: Datum nicht bestätigt" >&2
      ((count_failed+=1))
      continue
    fi

    if [[ -n "$manual_approved" && -n "$title" ]] &&
       [[ "$(jq -r '.title // empty' <<< "$verified")" != "$title" ]]; then
      echo "[FEHLER] Dokument $id: Titel nicht bestätigt" >&2
      ((count_failed+=1))
      continue
    fi

    tmp="$(mktemp)"
    jq '.applied = true | .applied_at = (now | todate)' "$file" > "$tmp"
    mv "$tmp" "$file"
    echo "[OK] Dokument $id: Vorschlag übernommen"
  else
    echo "[DRY-RUN] Dokument $id: Hauptkategorie=$primary; Datum=${date:-unverändert}; Korrespondent=${correspondent:-unverändert}"
    echo "[DRY-RUN] Dokument $id: zusätzliche Tags werden ergänzt; vorhandene Tags bleiben erhalten"
  fi

  ((count_applied+=1))
done

echo
echo "Modus: $MODE"
echo "Verarbeitet: $count_applied"
echo "Bereits erledigt/übersprungen: $count_skipped"
echo "Prüfung erforderlich: $count_review"
echo "Fehler: $count_failed"
