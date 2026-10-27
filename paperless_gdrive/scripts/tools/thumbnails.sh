#!/usr/bin/env bash
set -Eeuo pipefail

# Ein Dokument: Thumbnail neu erzeugen
# Verwendung: ./paperless-thumbnail.sh DOKUMENT_ID

if [[ $# -ne 1 || ! "$1" =~ ^[1-9][0-9]*$ ]]; then
    echo "Verwendung: $0 DOKUMENT_ID" >&2
    exit 2
fi

DOCUMENT_ID="$1"

mapfile -t CONTAINERS < <(
    docker ps --format '{{.Names}} {{.Image}}' |
    awk '$2 ~ /paperless-ngx\/paperless-ngx/ {print $1}'
)

if [[ ${#CONTAINERS[@]} -ne 1 ]]; then
    echo "Fehler: Erwartet genau einen laufenden Paperless-Container." >&2
    printf 'Gefunden: %s\n' "${CONTAINERS[*]:-(keiner)}" >&2
    echo "Bitte Containername im Skript gezielt konfigurieren." >&2
    exit 1
fi

CONTAINER="${CONTAINERS[0]}"

echo "Paperless-Container: $CONTAINER"
echo "Dokument-ID:         $DOCUMENT_ID"
echo
echo "Thumbnail-Erzeugung wird gestartet ..."

docker exec "$CONTAINER" \
    document_thumbnails --document "$DOCUMENT_ID"

echo
echo "Management-Befehl beendet."
echo "Bitte Thumbnail in Paperless im Browser kontrollieren."
