#!/usr/bin/env bash
# Analysiert Paperless-Dokumente ohne gültige Proposal-Datei und übernimmt
# geeignete Vorschläge automatisch über das bestehende Apply-Skript.
# Standard: automatische Übernahme; --dry-run verhindert Paperless-Schreibzugriffe.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/paperless_api.sh"

DRY_RUN=false
LIMIT=0

usage() {
    cat <<'EOF'
Aufruf: 04_gemini_missing_apply.sh [--dry-run] [--limit ANZAHL] [--help]

Standard: fehlende Vorschläge analysieren und geeignete Vorschläge automatisch übernehmen.
  --dry-run       Keine Änderungen in Paperless.
  --limit ZAHL    Höchstens ZAHL Dokumente bearbeiten (0 = alle).
  --apply         Kompatibilitätsoption; automatische Übernahme ist Standard.
  --help          Diese Hilfe anzeigen.
EOF
}

while (($#)); do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        --apply) DRY_RUN=false; shift ;;
        --limit)
            if (($# < 2)) || [[ ! "$2" =~ ^[0-9]+$ ]]; then
                echo "[FEHLER] --limit benötigt eine nichtnegative Zahl." >&2
                exit 2
            fi
            LIMIT="$2"
            shift 2
            ;;
        --help|-h) usage; exit 0 ;;
        *) echo "[FEHLER] Unbekannte Option: $1" >&2; usage; exit 2 ;;
    esac
done

pm_init
: "${PAPERLESS_TOKEN:?PAPERLESS_TOKEN fehlt}"
: "${GEMINI_API_KEY:?GEMINI_API_KEY fehlt}"

PROPOSALS="$PM_STATE/proposals"
mkdir -p "$PROPOSALS"

if ! NO_LLM_TAG_ID="$(pm_paperless_tag_id_by_name noLLM)" ||
   [[ ! "$NO_LLM_TAG_ID" =~ ^[0-9]+$ ]]; then
    echo "[FEHLER] Schutz-Tag noLLM fehlt oder konnte nicht eindeutig ermittelt werden; Abbruch." >&2
    exit 1
fi
echo "[INFO] Schutz-Tag noLLM gefunden: ID $NO_LLM_TAG_ID"

if ! all_ids="$(pm_paperless_all_ids)"; then
    echo "[FEHLER] Paperless-Dokumente konnten nicht gelesen werden." >&2
    exit 1
fi

skipped_no_llm=0

candidates=()
while IFS= read -r id; do
    [[ "$id" =~ ^[0-9]+$ ]] || continue

    if ! document_json="$(pm_paperless_document "$id")"; then
        echo "[FEHLER] Dokument $id konnte nicht geprüft werden; Abbruch." >&2
        exit 1
    fi

    if ! jq -e '.tags | type == "array"' <<< "$document_json" >/dev/null 2>&1; then
        echo "[FEHLER] Tags von Dokument $id sind nicht lesbar; Abbruch." >&2
        exit 1
    fi

    if jq -e --argjson tag_id "$NO_LLM_TAG_ID" \
        '(.tags | index($tag_id)) != null' \
        <<< "$document_json" >/dev/null; then
        ((skipped_no_llm+=1))
        continue
    fi

    proposal_file="$PROPOSALS/$id.json"
    if [[ -f "$proposal_file" ]] && jq -e . "$proposal_file" >/dev/null 2>&1; then
        continue
    fi

    candidates+=("$id")
    if (( LIMIT > 0 && ${#candidates[@]} >= LIMIT )); then
        break
    fi
done <<< "$all_ids"

total=${#candidates[@]}
analyzed=0
applied=0
skipped=0
failed=0

echo "[INFO] Dokumente ohne gültigen Vorschlag: $total"
if [[ "$DRY_RUN" == true ]]; then
    echo "[INFO] Modus: DRY-RUN; keine Änderungen in Paperless"
else
    echo "[INFO] Modus: automatische Übernahme geeigneter Vorschläge"
fi

for id in "${candidates[@]}"; do
    proposal_file="$PROPOSALS/$id.json"
    echo
    echo "[INFO] Dokument $id: Gemini-Analyse"

    if [[ -f "$proposal_file" ]] && jq -e . "$proposal_file" >/dev/null 2>&1; then
        echo "[SKIP] Vorschlag existiert inzwischen."
        ((skipped+=1))
        continue
    fi

    if ! "$SCRIPT_DIR/01_analyze.sh" --id "$id"; then
        echo "[FEHLER] Analyse für Dokument $id fehlgeschlagen." >&2
        ((failed+=1))
        continue
    fi

    if ! jq -e --argjson id "$id" \
        '.document_id == $id and (.proposal | type == "object")' \
        "$proposal_file" >/dev/null 2>&1; then
        echo "[FEHLER] Kein gültiger Vorschlag für Dokument $id." >&2
        ((failed+=1))
        continue
    fi

    ((analyzed+=1))
    echo "[INFO] Dokument $id: Vorschlag wird anhand der bestehenden Regeln geprüft"

    apply_args=(--id "$id")
    if [[ "$DRY_RUN" != true ]]; then
        apply_args+=(--apply)
    fi

    if "$SCRIPT_DIR/03_apply_proposals.sh" "${apply_args[@]}"; then
        if [[ "$DRY_RUN" != true ]] &&
           jq -e '.applied == true' "$proposal_file" >/dev/null 2>&1; then
            ((applied+=1))
            echo "[OK] Dokument $id: Vorschlag übernommen."
        else
            ((skipped+=1))
            if [[ "$DRY_RUN" == true ]]; then
                echo "[INFO] Dokument $id: DRY-RUN; keine Übernahme ausgeführt."
            else
                echo "[INFO] Dokument $id: nicht übernommen; Apply-Prüfungen oder Bestätigung nicht erfüllt."
            fi
        fi
    else
        ((failed+=1))
        echo "[FEHLER] Apply-Schritt für Dokument $id fehlgeschlagen." >&2
    fi
done

echo
echo "========== Zusammenfassung =========="
echo "[INFO] Dokumente ohne gültigen Vorschlag: $total"
echo "[INFO] Wegen noLLM übersprungen: $skipped_no_llm"
echo "Kandidaten:             $total"
echo "Analysen erfolgreich:   $analyzed"
if [[ "$DRY_RUN" == true ]]; then
    echo "Übernahmen bestätigt:   0 (DRY-RUN)"
else
    echo "Übernahmen bestätigt:   $applied"
fi
echo "Nicht übernommen:       $skipped"
echo "Fehler:                 $failed"

(( failed == 0 ))
