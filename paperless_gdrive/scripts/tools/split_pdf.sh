#!/bin/bash
# PDF in einzelne Seiten-PDFs aufteilen
# Aufruf:
#   pdf_split.sh datei.pdf
#   pdf_split.sh datei.pdf ausgabeordner

set -Eeuo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "Verwendung: $0 datei.pdf [ausgabeordner]" >&2
    exit 1
fi

INPUT="$1"

if [[ ! -f "$INPUT" ]]; then
    echo "Fehler: PDF nicht gefunden: $INPUT" >&2
    exit 1
fi

if ! command -v pdfseparate >/dev/null 2>&1; then
    echo "Fehler: pdfseparate fehlt. Installation: sudo apt install poppler-utils" >&2
    exit 1
fi

FILENAME="$(basename -- "$INPUT")"
BASENAME="${FILENAME%.*}"
INPUT_DIR="$(dirname -- "$INPUT")"
OUTDIR="${2:-"${INPUT_DIR}/${BASENAME}_seiten"}"

mkdir -p -- "$OUTDIR"

# Vorhandene gleichnamige Ausgabedateien nicht überschreiben.
if compgen -G "$OUTDIR/${BASENAME}_[0-9][0-9][0-9].pdf" >/dev/null; then
    echo "Fehler: Im Ausgabeordner existieren bereits passende PDF-Dateien:" >&2
    echo "$OUTDIR" >&2
    echo "Bitte einen neuen Ausgabeordner verwenden." >&2
    exit 1
fi

pdfseparate "$INPUT" "$OUTDIR/${BASENAME}_%03d.pdf"

echo "Aufteilung abgeschlossen."
echo "Ausgabeordner: $OUTDIR"
find "$OUTDIR" -maxdepth 1 -type f -name "${BASENAME}_[0-9][0-9][0-9].pdf" -printf '%f\n' | sort
