#!/usr/bin/env bash
# =============================================================================
# 07_reprocess_existing.sh
#
# Bestehende Paperless-Dokumente erneut analysieren und Metadaten anwenden.
#
# Kein Google-Drive-Upload, keine Archivierung und keine Dateilöschung.
#
# Standard: Dry-run
# Schreiben: --apply
# Einzelnes Dokument: --id ID
# =============================================================================

set -Eeuo pipefail

BASE_DIR="/home/pi/docker/paperless/paperless_metadata"
SCRIPT_DIR="${BASE_DIR}/scripts"

APPLY=false
DOCUMENT_ID=""

usage() {
    cat <<'EOF'
Verwendung:
  ./scripts/07_reprocess_existing.sh
  ./scripts/07_reprocess_existing.sh --id 697
  ./scripts/07_reprocess_existing.sh --apply
  ./scripts/07_reprocess_existing.sh --apply --id 697

Optionen:
  --apply       Änderungen in Paperless erlauben
  --id ID       Nur ein bestimmtes Dokument verarbeiten
  -h, --help    Hilfe anzeigen

Ohne --apply werden keine Paperless-Metadaten geschrieben.
EOF
}

while (($#)); do
    case "$1" in
        --apply)
            APPLY=true
            shift
            ;;
        --id)
            [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || {
                echo "FEHLER: --id benötigt eine numerische Dokument-ID." >&2
                exit 2
            }
            DOCUMENT_ID="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "FEHLER: Unbekannte Option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

cd "$BASE_DIR"

for script in \
    "${SCRIPT_DIR}/01_analyze.sh" \
    "${SCRIPT_DIR}/03_apply_proposals.sh" \
    "${SCRIPT_DIR}/06_dateinamen_vergleich.sh"
do
    [[ -x "$script" ]] || {
        echo "FEHLER: Skript fehlt oder ist nicht ausführbar: $script" >&2
        echo "Prüfe Dateiname und Berechtigungen." >&2
        exit 1
    }
done

[[ -n "${PAPERLESS_TOKEN:-}" ]] || {
    echo "FEHLER: PAPERLESS_TOKEN ist nicht gesetzt." >&2
    exit 1
}

[[ -n "${GEMINI_API_KEY:-}" ]] || {
    echo "FEHLER: GEMINI_API_KEY ist nicht gesetzt." >&2
    exit 1
}

echo "============================================================"
echo "Paperless: vorhandene Dokumente erneut verarbeiten"
echo "============================================================"
echo "Modus:       $([[ "$APPLY" == true ]] && echo APPLY || echo DRY-RUN)"
echo "Dokument-ID: ${DOCUMENT_ID:-ALLE}"
echo "Archivierung: NEIN"
echo

# 1. Gemini-Analyse erneut durchführen.
echo "=== Schritt 1: Analyse ==="

if [[ -n "$DOCUMENT_ID" ]]; then
    "${SCRIPT_DIR}/01_analyze.sh" --id "$DOCUMENT_ID"
else
    "${SCRIPT_DIR}/01_analyze.sh"
fi

# 2. Vorhandene Apply-Logik auf die neuen Vorschläge anwenden.
echo
echo "=== Schritt 2: Metadaten ==="

APPLY_ARGS=()
if [[ "$APPLY" == true ]]; then
    APPLY_ARGS+=(--apply)
fi
if [[ -n "$DOCUMENT_ID" ]]; then
    APPLY_ARGS+=(--id "$DOCUMENT_ID")
fi

"${SCRIPT_DIR}/03_apply_proposals.sh" "${APPLY_ARGS[@]}"

# 3. Dateinamenbericht erstellen.
# Dieser Schritt prüft die vorgeschlagenen Namen; er benennt selbst
# keine Dateien um.
echo
echo "=== Schritt 3: Dateinamen prüfen ==="

"${SCRIPT_DIR}/06_dateinamen_vergleich.sh"

echo
echo "============================================================"
echo "Verarbeitung abgeschlossen."
echo "============================================================"

if [[ "$APPLY" == true ]]; then
    echo "Metadaten wurden zur Anwendung übergeben."
    echo "Die tatsächliche interne Dateiumbenennung ist damit"
    echo "noch nicht garantiert; sie hängt von Paperless ab."
else
    echo "DRY-RUN: Keine Paperless-Metadaten wurden durch dieses"
    echo "Skript zum Schreiben freigegeben."
fi

echo "Bitte den Dateinamenbericht auf Konflikte prüfen."
