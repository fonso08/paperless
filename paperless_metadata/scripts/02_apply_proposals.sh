#!/usr/bin/env bash
# Übernimmt freigegebene Gemini-Vorschläge in Paperless.
# Standard: Dry-Run. Schreiben nur mit --apply.
set -euo pipefail

source "$(dirname "$0")/lib/paperless_api.sh"
pm_init

MODE="apply"
ONLY_ID=""
LIMIT=0


while (($#)); do
  case "$1" in
    --apply)
      MODE="apply"
      ;;
    --dry-run)
      MODE="dry-run"
      ;;
    --id)
      [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || {
        echo "Aufruf: $0 [--id NUMMER] [--limit ANZAHL] [--dry-run|--apply]" >&2
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
      echo "Aufruf: $0 [--id NUMMER] [--limit ANZAHL] [--dry-run|--apply]" >&2
      exit 2
      ;;
  esac
  shift
done

: "${PAPERLESS_TOKEN:?PAPERLESS_TOKEN fehlt}"
: "${PAPERLESS_URL:?PAPERLESS_URL fehlt}"

PROPOSALS="$PM_STATE/proposals"
BACKUPS="$PM_STATE/applied_backups"
APPLY_INDEX="$PM_STATE/apply_candidates.json"

mkdir -p "$BACKUPS"

# Index einmalig aufbauen, wenn er fehlt oder ungültig ist.
# Danach wird bei normalen Läufen nur noch der Index gelesen.
rebuild_apply_index() {
  local file
  local ids_tmp

  ids_tmp="$(mktemp "${TMPDIR:-/tmp}/pm-apply-ids.XXXXXX")"

  shopt -s nullglob
  for file in "$PROPOSALS"/*.json; do
    jq -e '
      .applied != true and
      (.document_id | numbers) and
      (.proposal | type == "object") and
      (.model != "manual-noLLM") and
      (.provider != "none") and
      ((.proposal.primary_tag // "") | type == "string" and length > 0)
    ' "$file" >/dev/null 2>&1 || continue

    jq -r '.document_id' "$file" >> "$ids_tmp"
  done
  shopt -u nullglob

  jq -Rsc '
    split("\\n")
    | map(select(test("^[0-9]+$")) | tonumber)
    | unique
  ' "$ids_tmp" | pm_atomic_json "$APPLY_INDEX"

  rm -f "$ids_tmp"

  echo "[INFO] Apply-Index neu aufgebaut: $(jq 'length' "$APPLY_INDEX") IDs"
}

if [[ ! -f "$APPLY_INDEX" ]] ||
   ! jq -e '
     type == "array" and
     all(.[]; type == "number" and floor == . and . > 0)
   ' "$APPLY_INDEX" >/dev/null 2>&1; then
  rebuild_apply_index
fi

# Einzelne ID nach erfolgreicher Anwendung aus dem Index entfernen.
remove_apply_candidate() {
  local id="$1"
  local tmp

  tmp="$(mktemp "${TMPDIR:-/tmp}/pm-apply-index.XXXXXX")"

  if ! jq --argjson id "$id" \
    '[.[] | select(. != $id)]' "$APPLY_INDEX" > "$tmp"; then
    rm -f "$tmp"
    echo "[FEHLER] Apply-Index konnte nicht aktualisiert werden." >&2
    return 1
  fi

  if ! jq -e '
    type == "array" and
    all(.[]; type == "number" and floor == . and . > 0)
  ' "$tmp" >/dev/null; then
    rm -f "$tmp"
    echo "[FEHLER] Neuer Apply-Index ist ungültig." >&2
    return 1
  fi

  mv "$tmp" "$APPLY_INDEX"
}
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

files=()

if [[ -n "$ONLY_ID" ]]; then
  file="$PROPOSALS/$ONLY_ID.json"

  [[ -f "$file" ]] || {
    echo "Proposal nicht gefunden: $file" >&2
    exit 1
  }

  files+=("$file")
else
  while IFS= read -r id; do
    [[ "$id" =~ ^[0-9]+$ ]] || continue

    candidate="$PROPOSALS/$id.json"
    [[ -f "$candidate" ]] || continue

    # Die Index-ID muss zum Dokument in der Datei passen.
    jq -e --argjson id "$id" '
      .document_id == $id and
      .applied != true and
      (.proposal | type == "object") and
      (.model != "manual-noLLM") and
      (.provider != "none") and
      ((.proposal.primary_tag // "") | type == "string" and length > 0)
    ' "$candidate" >/dev/null 2>&1 || continue

    files+=("$candidate")

    if (( LIMIT > 0 && ${#files[@]} >= LIMIT )); then
      break
    fi
  done < <(jq -r '.[]' "$APPLY_INDEX")
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

  id="$(jq -r '.document_id' "$file")"
  [[ -z "$ONLY_ID" || "$id" == "$ONLY_ID" ]] || continue

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
	+ (if $title != "" then {title:$title} else {} end)
#        + (if $title != "" and $manual_approved != "" then {title:$title} else {} end)
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

    if [[ -n "$title" ]] &&
       [[ "$(jq -r '.title // empty' <<< "$verified")" != "$title" ]]; then
#    if [[ -n "$manual_approved" && -n "$title" ]] &&
#       [[ "$(jq -r '.title // empty' <<< "$verified")" != "$title" ]]; then
      echo "[FEHLER] Dokument $id: Titel nicht bestätigt" >&2
      ((count_failed+=1))
      continue
    fi

tmp="$(mktemp)"

if ! jq '.applied = true | .applied_at = (now | todate)' \
  "$file" > "$tmp"; then
  rm -f "$tmp"
  echo "[FEHLER] Dokument $id: Proposal konnte nicht aktualisiert werden." >&2
  ((count_failed+=1))
  continue
fi

if ! mv "$tmp" "$file"; then
  rm -f "$tmp"
  echo "[FEHLER] Dokument $id: Proposal konnte nicht gespeichert werden." >&2
  ((count_failed+=1))
  continue
fi

if [[ "$MODE" == "apply" ]] && [[ -z "$ONLY_ID" ]]; then
  if ! remove_apply_candidate "$id"; then
    echo "[FEHLER] Dokument $id: Übernahme bestätigt, Indexbereinigung fehlgeschlagen." >&2
    ((count_failed+=1))
    continue
  fi
fi

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
