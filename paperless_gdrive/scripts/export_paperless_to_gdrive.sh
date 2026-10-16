#!/usr/bin/env bash
set -Eeuo pipefail

# Fortschrittsmeldungen mit Zeitstempel
progress() {
    printf '[%s] [FORTSCHRITT] %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

# Lebenszeichen alle 30 Sekunden
heartbeat() {
    while sleep 30; do
        progress "Skript läuft weiterhin; Details siehe letzte Fortschrittsmeldung."
    done
}

CURRENT_STEP="Initialisierung"
heartbeat &
HEARTBEAT_PID=$!

cleanup_heartbeat() {
    kill "$HEARTBEAT_PID" 2>/dev/null || true
    wait "$HEARTBEAT_PID" 2>/dev/null || true
}
trap cleanup_heartbeat EXIT

BASE_DIR="/home/pi/docker/paperless/paperless_gdrive"
EXPORT_DIR="/media/BlueDisc3/PAPERLESS/export"
STAGE_DIR="/media/BlueDisc3/PAPERLESS/export_gdrive_staging"
REMOTE="gdrive:PAPERLESS"
PROPOSALS_DIR="/media/BlueDisc3/PAPERLESS/state/metadata/proposals"

MODE="dry-run"
if [[ "${1:-}" == "--upload" ]]; then
    MODE="upload"
elif [[ "${1:-}" == "--help" ]]; then
    echo "Verwendung: $0 [--upload]"
    echo "Standard: Dry-Run ohne Upload."
    exit 0
elif [[ $# -gt 0 ]]; then
    echo "Unbekannte Option: $1" >&2
    exit 2
fi

for cmd in jq rclone; do
    command -v "$cmd" >/dev/null || {
        echo "FEHLER: $cmd ist nicht installiert." >&2
        exit 1
    }
done

[[ -f "$EXPORT_DIR/manifest.json" ]] || {
    echo "FEHLER: $EXPORT_DIR/manifest.json fehlt." >&2
    echo "Bitte zuerst den Paperless-Export durchführen." >&2
    exit 1
}

sanitize() {
    local value="$1"

    value="${value//$'\n'/ }"
    value="${value//$'\r'/ }"
    value="${value//\//-}"
    value="${value//\\/-}"
    value="${value//:/-}"
    value="${value//\*/-}"
    value="${value//\?/-}"
    value="${value//\"/-}"
    value="${value//</-}"
    value="${value//>/-}"
    value="${value//|/-}"
    value="${value// /_}"

    value="$(printf '%s' "$value" |
        sed -E 's/_+/_/g; s/^[_. -]+//; s/[_. -]+$//')"

    printf '%s' "${value:0:160}"
}

# Vorhandene Paperless-API-Konfiguration verwenden
cd "$BASE_DIR"
source scripts/lib/common.sh
source scripts/lib/paperless_api.sh

echo "Lese Paperless-Tags und Korrespondenten ..."

CURRENT_STEP="Paperless-Tags abrufen"
progress "Rufe Paperless-Tags ab ..."
TAGS_JSON="$(paperless_curl "$(paperless_api_url 'tags/?page_size=1000')")"
progress "Tags erfolgreich abgerufen."

CURRENT_STEP="Paperless-Korrespondenten abrufen"
progress "Rufe Paperless-Korrespondenten ab ..."
CORR_JSON="$(paperless_curl "$(paperless_api_url 'correspondents/?page_size=1000')")"
progress "Korrespondenten erfolgreich abgerufen."

TAG_MAP="$(printf '%s' "$TAGS_JSON" | jq -c '
    [(.results // .)[] | {key:(.id|tostring), value:.name}]
    | from_entries
')"

CORR_MAP="$(printf '%s' "$CORR_JSON" | jq -c '
    [(.results // .)[] | {key:(.id|tostring), value:.name}]
    | from_entries
')"

mkdir -p "$STAGE_DIR"

# Vorhandenes Staging erhalten; bereits vorbereitete Dateien werden wiederverwendet.

seen=0
prepared=0
skipped=0

# Manifest-Pfade vollständig in ein Array einlesen.
# So werden die Pfade anschließend direkt aus dem Array verarbeitet.
CURRENT_STEP="Manifest-Dateien einlesen"

mapfile -d '' -t manifests < <(
    find "$EXPORT_DIR" -maxdepth 1 -type f \
        -name '*.json' \
        ! -name 'manifest.json' \
        ! -name 'metadata.json' \
        -print0
)

manifest_total=${#manifests[@]}
progress "Starte Verarbeitung von $manifest_total Dokumentmanifesten."

for manifest in "${manifests[@]}"; do
    progress "BEGINNE Manifest: $(basename "$manifest")"
    ((seen+=1))
    CURRENT_STEP="Manifest $seen von $manifest_total"

    if (( seen == 1 || seen % 5 == 0 )); then
        progress "Manifest $seen/$manifest_total; $prepared PDFs vorbereitet, $skipped übersprungen."
    fi

    [[ "$(basename "$manifest")" == "manifest.json" ]] && continue

    exported_name="$(jq -r '.[0].__exported_file_name__ // empty' "$manifest")"
    [[ -n "$exported_name" ]] || continue

    # PDFs und Bilder übernehmen; TXT und andere Formate ignorieren.
    source_ext="${exported_name##*.}"
    case "${source_ext,,}" in
        pdf|jpg|jpeg|png) ;;
        *) continue ;;
    esac

    # Paperless-Archiv-PDFs nicht zusätzlich exportieren.
    [[ "${exported_name,,}" != *-archive.pdf ]] || continue

    source_file="$EXPORT_DIR/$exported_name"

    if [[ ! -f "$source_file" ]]; then
        echo "ÜBERSPRUNGEN: Quelldatei fehlt: $exported_name"
        ((skipped+=1))
        continue
    fi

    doc="$(jq -c '.[0]' "$manifest")"
    doc_id="$(jq -r '.pk // empty' <<< "$doc")"
    title="$(jq -r '.fields.title // empty' <<< "$doc")"
    date="$(jq -r '.fields.created // empty' <<< "$doc")"
    correspondent_id="$(jq -r '.fields.correspondent // empty' <<< "$doc")"

    # Vorrang: bestätigter Gemini-Haupttag.
    # Rückfall: genau ein vorhandener Paperless-Tag.
    category=""
    proposal_file="$PROPOSALS_DIR/$doc_id.json"

    if [[ -n "$doc_id" && -f "$proposal_file" ]]; then
        category="$(jq -r '
            select(.applied == true)
            | .proposal.primary_tag
            | select(type == "string" and length > 0)
        ' "$proposal_file" 2>/dev/null || true)"
    fi

    if [[ -z "$category" ]]; then
        mapfile -t doc_tags < <(
            jq -n -r \
                --argjson fields "$(jq -c '.fields' <<< "$doc")" \
                --argjson tagmap "$TAG_MAP" '
                ($fields.tags // [])
                | map(tostring)
                | map($tagmap[.] // "")
                | map(select(length > 0))
                | unique[]
            ' 2>/dev/null
        )

        if (( ${#doc_tags[@]} == 1 )); then
            category="${doc_tags[0]}"
        elif (( ${#doc_tags[@]} > 1 )); then
            echo "PRÜFEN: Dokument $doc_id hat keinen bestätigten Gemini-Haupttag und mehrere Paperless-Tags: ${doc_tags[*]}"
            ((skipped+=1))
            continue
        else
            category="UNSORTIERT"
        fi
    fi

    correspondent=""
    if [[ -n "$correspondent_id" && "$correspondent_id" != "null" ]]; then
        correspondent="$(
            jq -r --arg id "$correspondent_id" '.[$id] // empty' <<< "$CORR_MAP"
        )"
    fi

    if [[ -z "$title" || "$title" == "null" ]]; then
        title="$(jq -r '.[0].fields.original_filename // empty' "$manifest")"
        title="${title%.*}"
    fi

    [[ -n "$title" ]] || title="Dokument-$doc_id"

    safe_category="$(sanitize "$category")"
    safe_title="$(sanitize "$title")"

    if [[ -n "$correspondent" && "$correspondent" != "null" ]]; then
        safe_corr="$(sanitize "$correspondent")"
        folder="$safe_category/$safe_corr"

        if [[ "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
            filename="${date//-/}_${safe_category}_${safe_corr}_${safe_title}"
        else
            filename="${safe_category}_${safe_corr}_${safe_title}"
        fi
    else
        folder="$safe_category/SONSTIGES"

        if [[ "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
            filename="${date//-/}_${safe_category}_${safe_title}"
        else
            filename="${safe_category}_${safe_title}"
        fi
    fi

    destination_dir="$STAGE_DIR/$folder"
    mkdir -p "$destination_dir"

    # Maximal 80 Zeichen einschließlich der tatsächlichen Dateiendung.
    max_stem=$((80 - ${#source_ext} - 1))
    filename="${filename:0:$max_stem}"
    destination="$destination_dir/$filename.$source_ext"

    # Vorhandene identische Staging-Dateien wiederverwenden.
    if [[ -e "$destination" ]]; then
        if [[ -f "$destination" ]] && cmp -s -- "$source_file" "$destination"; then
            progress "BEREITS VORBEREITET: ${folder}/$(basename "$destination")"
            continue
        fi

        # Abweichende Dateien durch die Paperless-Dokument-ID unterscheiden.
        suffix="_ID-${doc_id}"
        available=$((max_stem - ${#suffix}))

        if (( available < 1 )); then
            echo "FEHLER: Dokument-ID zu lang für einen sicheren Dateinamen."
            ((skipped+=1))
            continue
        fi

        filename="${filename:0:$available}${suffix}"
        destination="$destination_dir/$filename.$source_ext"
    fi

    if [[ -e "$destination" ]]; then
        if [[ -f "$destination" ]] && cmp -s -- "$source_file" "$destination"; then
            progress "BEREITS VORBEREITET: ${folder}/$(basename "$destination")"
            continue
        fi
        echo "FEHLER: Auch Ausweichname existiert: $destination"
        ((skipped+=1))
        continue
    fi

    progress "KOPIERE: $exported_name"
    cp -- "$source_file" "$destination"
    ((prepared+=1))

    relative="${folder}/$(basename "$destination")"
    printf '%s\n' "VORBEREITET: $relative"
done

echo
echo "===== Ergebnis ====="
echo "Geprüfte Manifestdateien: $seen"
echo "Für Export vorbereitet:  $prepared"
echo "Übersprungen:            $skipped"
echo "Staging-Verzeichnis:     $STAGE_DIR"
echo "Modus:                   $MODE"

if [[ "$MODE" == "dry-run" ]]; then
    echo
    echo "DRY-RUN: Es wurde nichts zu Google Drive hochgeladen."
    echo "Prüfe die Dateinamen und Ordner im Staging-Verzeichnis."
    echo "Für den tatsächlichen Upload später: $0 --upload"
    exit 0
fi

echo
echo "Lade Dateien nach $REMOTE hoch (vorhandene Dateien werden nicht überschrieben) ..."

if ! rclone copy "$STAGE_DIR" "$REMOTE" \
    --ignore-existing \
    --create-empty-src-dirs \
    --log-level INFO; then
    echo "FEHLER: rclone-Upload fehlgeschlagen." >&2
    exit 1
fi

echo
echo "Prüfe Dateien im Staging gegen Google Drive ..."

if ! rclone check "$STAGE_DIR" "$REMOTE" \
    --one-way \
    --log-level INFO; then
    echo "FEHLER: Upload-Prüfung fehlgeschlagen oder Dateien weichen ab." >&2
    echo "Staging-Dateien bleiben unverändert erhalten." >&2
    exit 1
fi

echo
echo "ERFOLG: Die Dateien im Staging wurden gegen Google Drive geprüft."
echo "Es wurden keine Quelldateien gelöscht."
