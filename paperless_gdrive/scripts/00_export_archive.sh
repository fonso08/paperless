#!/usr/bin/env bash
# Exportiert Paperless-Dokumente, die im Google-Drive-Archiv noch fehlen.
# Standard: tatsächlicher Export. Dry-Run nur mit --dry-run.
# WICHTIG: Dieses Skript löscht weder Paperless-Originale noch GDrive-Dateien.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/paperless_api.sh"

init_directories
check_common_requirements

# Standard: tatsächlicher Export
APPLY=true
INIT=false
DRY_RUN=false

while (($#)); do
  case "$1" in
    --apply)
      APPLY=true
      DRY_RUN=false
      ;;
    --dry-run)
      APPLY=false
      DRY_RUN=true
      ;;
    --init)
      APPLY=true
      INIT=true
      DRY_RUN=false
      ;;
    -h|--help)
      cat <<'HELP'
Verwendung: 04_export_archive.sh [--apply|--dry-run|--init]

Ohne Option:
  Exportiert fehlende Dokumente tatsächlich.

--apply:
  Exportiert fehlende Dokumente tatsächlich.

--dry-run:
  Zeigt fehlende Dokumente an, ohne sie hochzuladen.

--init:
  Exportiert nach Sicherheitsabfrage alle Dokumente erneut.
  Vorhandene Zieldateien können überschrieben werden.

Es werden keine Quellen gelöscht und keine Paperless-Metadaten verändert.
HELP
      exit 0
      ;;
    *)
      echo "Unbekannte Option: $1" >&2
      exit 2
      ;;
  esac
  shift
done
if [[ "$INIT" == true ]]; then
  echo "ACHTUNG: --init exportiert ALLE Dokumente aus Paperless-ngx erneut."
  echo "Dateien am berechneten Zielpfad in Google Drive werden dabei ÜBERSCHRIEBEN."
  echo "Paperless-Originale und andere GDrive-Dateien werden nicht gelöscht."
  read -r -p 'Zum Fortfahren exakt JA eingeben: ' confirmation
  [[ "$confirmation" == "JA" ]] || {
    echo 'Abgebrochen; es wurden keine Dateien exportiert.'
    exit 0
  }
fi

: "${PAPERLESS_TOKEN:?PAPERLESS_TOKEN ist nicht gesetzt}"
: "${GDRIVE_ARCHIVE:?GDRIVE_ARCHIVE ist nicht gesetzt}"
command -v jq >/dev/null || { echo 'FEHLER: jq fehlt.' >&2; exit 1; }
command -v rclone >/dev/null || { echo 'FEHLER: rclone fehlt.' >&2; exit 1; }

METADATA_ROOT="${METADATA_ROOT:-/home/pi/docker/paperless/paperless_metadata}"
METADATA_STATE="${STATE_DIR:-/media/BlueDisc3/PAPERLESS/state}/metadata"

# Dauerhaftes Exportprotokoll.
EXPORT_LOG_DIR="${EXPORT_LOG_DIR:-/media/BlueDisc3/PAPERLESS/logs}"
mkdir -p "$EXPORT_LOG_DIR" || {
  echo "FEHLER: Logverzeichnis nicht erreichbar: $EXPORT_LOG_DIR" >&2
  exit 1
}
LOG_FILE="$EXPORT_LOG_DIR/04_export_missing_archive_$(date '+%Y%m%d_%H%M%S').log"
: > "$LOG_FILE" || {
  echo "FEHLER: Logdatei kann nicht angelegt werden: $LOG_FILE" >&2
  exit 1
}

TMP_EXPORT="${TMP_DIR:-/tmp}/paperless_archive_export_$$"
mkdir -p "$TMP_EXPORT"
trap 'rm -rf -- "$TMP_EXPORT"' EXIT

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"
}
fail() {
  log "FEHLER: $*" >&2
  exit 1
}

safe_name() {
  local v="$1"
  v="${v//$'\n'/ }"
  v="${v//$'\r'/ }"
  v="${v//\//-}"
  v="${v//\\/-}"
  v="${v//:/-}"
  v="${v//\*/-}"
  v="${v//\?/-}"
  v="${v//\"/-}"
  v="${v//</-}"
  v="${v//>/-}"
  v="${v//|/-}"
  v="${v// /_}"
  printf '%s' "$v" |
    sed -E 's/_+/_/g; s/^[_. -]+//; s/[_. -]+$//'
}

is_main_category() {
  case "$1" in
    Wohnen|Finanzen|Versicherungen|Gesundheit|Beruf|Behörden|\
    Verträge|Einkäufe|Bildung|Mobilität|Familie|Freizeit|Sonstiges)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Gleiche Dateinamensbildung wie in 03_process_jobs_archive.sh.
metadata_filename() {
  local did="$1" category="$2" corr="$3" date="$4"
  local title="$5" source_name="$6"
  local ext stem suffix max

  ext="${source_name##*.}"
  ext="${ext,,}"
  case "$ext" in
    pdf|jpg|jpeg|png) ;;
    *) return 1 ;;
  esac

  category="$(safe_name "$category")"
  corr="$(safe_name "$corr")"
  title="$(safe_name "$title")"
  [[ -n "$category" && -n "$corr" ]] || return 1

  if [[ "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    stem="${date//-/}_${category}_${corr}_${title}"
  else
    stem="${category}_${corr}_${title}"
  fi

  suffix="_ID-${did}"
  max=$((80 - ${#ext} - 1 - ${#did} - 4))
  (( max > 0 )) || return 1
  printf '%s%s.%s\n' "${stem:0:max}" "$suffix" "$ext"
}

api_get() {
  paperless_curl "$(paperless_api_url "$1")"
}

# Metadaten bevorzugt aus einer angewendeten Gemini-Proposal.
# Sonst vorhandene Paperless-Tags und Paperless-Felder verwenden.
get_export_metadata() {
  local doc_json="$1" did="$2"
  local tags category corr_id corr date title original proposal tag

tags=""

while IFS= read -r tag_id; do
  [[ "$tag_id" =~ ^[0-9]+$ ]] || continue

  tag_name="$(api_get "tags/${tag_id}/" |
    jq -r '.name // empty')" || return 1

  [[ -n "$tag_name" ]] && tags+="${tag_name}"$'\n'
done < <(jq -r '.tags[]?' <<< "$doc_json")

    category=""
  date=""
  proposal="$METADATA_STATE/proposals/${did}.json"

  # Eine angewendete Gemini-Proposal hat Vorrang,
  # aber nur mit einer gültigen Paperless-Hauptkategorie.
  if [[ -f "$proposal" ]] &&
     jq -e '.applied == true' "$proposal" >/dev/null 2>&1; then

    proposal_category="$(jq -r '.proposal.primary_tag // empty' \
      "$proposal")"

    if is_main_category "$proposal_category"; then
      category="$proposal_category"
      date="$(jq -r '.proposal.document_date // empty' "$proposal")"
    fi
  fi

  # Ohne gültige Kategorie aus der Proposal die Paperless-Tags prüfen.
  if [[ -z "$category" ]]; then
    category_count=0

    while IFS= read -r tag; do
      if is_main_category "$tag"; then
        category="$tag"
        category_count=$((category_count + 1))
      fi
    done <<< "$tags"

    # Keine oder mehrere Hauptkategorien: nicht archivieren.
    if (( category_count != 1 )); then
      category=""
    fi

    # Ohne gültige freigegebene Proposal kein Datum voranstellen.
    date=""
  fi
  corr_id="$(jq -r '.correspondent // empty' <<< "$doc_json")"
  corr="SONSTIGES"

  if [[ -n "$corr_id" && "$corr_id" != "null" ]]; then
    corr="$(api_get "correspondents/${corr_id}/" |
      jq -r '.name // empty')" || return 1
    [[ -n "$corr" ]] || corr="SONSTIGES"
  fi

  title="$(jq -r '.title // "Dokument"' <<< "$doc_json")"
  original="$(jq -r '.original_file_name // .filename // empty' <<< "$doc_json")"
  [[ -n "$original" ]] ||
    original="$(jq -r '.archive_serial_number // empty' <<< "$doc_json")"

  printf '%s\n%s\n%s\n%s\n%s\n' \
    "$category" "$corr" "$date" "$title" "$original"
}

log "Export gestartet. Logdatei: $LOG_FILE"
log "Modus: $(
  [[ "$INIT" == true ]] && echo INIT ||
  ([[ "$APPLY" == true ]] && echo APPLY || echo DRY-RUN)
)"
log "Lese vorhandene Archivdateien aus ${GDRIVE_ARCHIVE} ..."

# Fehler beim Lesen des Remote-Archivs müssen den Lauf abbrechen.
if ! rclone lsf --recursive --files-only "$GDRIVE_ARCHIVE" \
  > "$TMP_EXPORT/archive_files.txt"; then
  fail "Google-Drive-Archiv konnte nicht vollständig gelesen werden; kein Export durchgeführt."
fi

# IDs, die bereits in irgendeinem Dateinamen vorkommen.
grep -Eo '(^|/)?.*_ID-[0-9]+\.[[:alnum:]]+$' \
  "$TMP_EXPORT/archive_files.txt" |
  grep -Eo '_ID-[0-9]+\.' |
  sed -E 's/_ID-([0-9]+)\./\1/' |
  sort -u > "$TMP_EXPORT/archived_ids.txt" || true

# Alle Paperless-Dokumente seitenweise einlesen.
next="documents/?page_size=100"
seen=0
already=0
missing=0
exported=0
failed=0

while [[ -n "$next" && "$next" != "null" ]]; do
  page="$(api_get "$next")" ||
    fail "Paperless-API-Seite konnte nicht gelesen werden: $next"

  jq -e '.results | type == "array"' <<< "$page" >/dev/null ||
    fail "Unerwartetes Paperless-API-Format."

  while IFS= read -r doc; do
    did="$(jq -r '.id' <<< "$doc")"
    [[ "$did" =~ ^[0-9]+$ ]] ||
      fail "Ungültige Dokument-ID in API-Antwort."

    seen=$((seen + 1))

    if [[ "$INIT" != true ]] &&
       grep -Fxq "$did" "$TMP_EXPORT/archived_ids.txt"; then
      already=$((already + 1))
      continue
    fi

    if [[ "$INIT" != true ]]; then
      missing=$((missing + 1))
    fi

    mapfile -t meta < <(get_export_metadata "$doc" "$did") || {
      log "Dokument $did: Metadaten konnten nicht ermittelt werden; übersprungen."
      failed=$((failed + 1))
      continue
    }

    category="${meta[0]:-}"
    corr="${meta[1]:-SONSTIGES}"

    if [[ -z "$category" ]] || ! is_main_category "$category"; then
      log "WARNUNG: Dokument $did: keine eindeutige gültige Hauptkategorie in Paperless; Archivierung übersprungen."
      failed=$((failed + 1))
      continue
    fi

    date="${meta[2]:-}"
    title="${meta[3]:-Dokument}"
    original="${meta[4]:-}"

    [[ -n "$original" ]] || original="document-${did}.pdf"

    filename="$(metadata_filename "$did" "$category" "$corr" "$date" "$title" "$original")" || {
      log "Dokument $did: Dateityp nicht unterstützt/Dateiname nicht bildbar ($original); übersprungen."
      failed=$((failed + 1))
      continue
    }

    target="${GDRIVE_ARCHIVE%/}/$(safe_name "$category")/$(safe_name "$corr")/$filename"

    # Zusätzlicher Schutz gegen identischen Zielpfad.
    if [[ "$INIT" != true ]] &&
       grep -Fqx -- "${target#${GDRIVE_ARCHIVE%/}/}" \
         "$TMP_EXPORT/archive_files.txt"; then
      already=$((already + 1))
      continue
    fi

    if [[ "$INIT" == true ]]; then
      log "INIT-EXPORT (überschreibt ggf.): Paperless-ID=$did -> $target"
    else
      log "FEHLT: Paperless-ID=$did -> $target"
    fi

    if [[ "$APPLY" != true ]]; then
      continue
    fi

    localfile="$TMP_EXPORT/document-${did}.${filename##*.}"

    if ! curl -fsS --connect-timeout 10 --max-time 300 \
      -H "Authorization: Token ${PAPERLESS_TOKEN}" \
      -H 'Accept: */*' \
      "$(paperless_api_url "documents/${did}/download/")" \
      -o "$localfile"; then
      log "Dokument $did: Download fehlgeschlagen."
      failed=$((failed + 1))
      continue
    fi

    [[ -s "$localfile" ]] || {
      log "Dokument $did: heruntergeladene Datei leer."
      failed=$((failed + 1))
      continue
    }

    if [[ "$INIT" != true ]] &&
       rclone lsf "${target%/*}" >/dev/null 2>&1; then
      if rclone lsf --files-only "${target%/*}" |
         grep -Fqx -- "$filename"; then
        log "Dokument $did: Ziel existiert inzwischen; Upload übersprungen."
        already=$((already + 1))
        continue
      fi
    fi

    # rclone copyto ersetzt bei --init eine vorhandene Datei am Zielpfad.
    if ! rclone copyto "$localfile" "$target"; then
      log "Dokument $did: Upload fehlgeschlagen."
      failed=$((failed + 1))
      continue
    fi

    local_size="$(stat -c '%s' "$localfile")"
    remote_size="$(rclone size "$target" --json | jq -r '.bytes // 0')" || {
      log "Dokument $did: Remote-Verifikation fehlgeschlagen."
      failed=$((failed + 1))
      continue
    }

    if [[ "$local_size" != "$remote_size" ]]; then
      log "Dokument $did: Größenabweichung lokal=$local_size remote=$remote_size; bitte prüfen."
      failed=$((failed + 1))
      continue
    fi

    printf '%s\n' "$did" >> "$TMP_EXPORT/archived_ids.txt"
    exported=$((exported + 1))
    log "Dokument $did: Upload verifiziert."

  done < <(jq -c '.results[]' <<< "$page")

  next="$(jq -r '.next // empty' <<< "$page")"

  if [[ "$next" == http://* || "$next" == https://* ]]; then
    # API helper erwartet relative Pfade.
    next="${next#*://*/api/}"
  fi
done

log "Zusammenfassung: geprüft=$seen bereits_archiviert=$already fehlend=$missing exportiert=$exported fehler=$failed"

if [[ "$DRY_RUN" == true ]]; then
  log "Dry-Run beendet. Für den tatsächlichen Export das Skript ohne Option oder mit --apply starten."
fi

(( failed == 0 )) || exit 1
