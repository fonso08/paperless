#!/usr/bin/env bash
set -euo pipefail
cd /home/pi/docker/paperless
python3 - <<'PY'
from pathlib import Path

changes = {
    Path('paperless_metadata/scripts/lib/paperless_api.sh'): [(
'''  jq -er --arg name "$name" '
    [.[] | select(.name == $name) | .id]
    | if length == 1 then .[0]
      else error("Tag fehlt oder ist nicht eindeutig: " + $name)
      end
  ' <<< "$catalog"
''',
'''  jq -r --arg name "$name" '
    [.[] | select(.name == $name) | .id]
    | if length == 0 then ""
      elif length == 1 then .[0]
      else error("Tag ist nicht eindeutig: " + $name)
      end
  ' <<< "$catalog"
''')],
    Path('paperless_metadata/scripts/01_analyze.sh'): [(
'''NO_LLM_TAG_ID="$(pm_paperless_tag_id_by_name noLLM)" || {
  pm_log ERROR "Tag noLLM konnte nicht sicher ermittelt werden; Abbruch"
  exit 1
}

pm_log INFO "Schutz-Tag noLLM gefunden: ID $NO_LLM_TAG_ID"
''',
'''if ! NO_LLM_TAG_ID="$(pm_paperless_tag_id_by_name noLLM)"; then
  pm_log ERROR "Paperless-Tag-Katalog konnte nicht sicher gelesen werden; Abbruch"
  exit 1
fi

if [[ -n "$NO_LLM_TAG_ID" ]]; then
  pm_log INFO "Schutz-Tag noLLM gefunden: ID $NO_LLM_TAG_ID"
else
  pm_log WARN "Tag noLLM fehlt; Gemini-Verarbeitung läuft ohne Tag-Filter weiter"
fi
'''), (
'''if jq -e --argjson tag_id "$NO_LLM_TAG_ID" \\
    '(.tags | index($tag_id)) != null' \\
    "$document_file" >/dev/null; then
''',
'''if [[ -n "$NO_LLM_TAG_ID" ]] && jq -e --argjson tag_id "$NO_LLM_TAG_ID" \\
    '(.tags | index($tag_id)) != null' \\
    "$document_file" >/dev/null; then
''')],
    Path('paperless_metadata/scripts/03_update_all_missing_gemini.sh'): [(
'''NO_LLM_TAG_ID="$(pm_paperless_tag_id_by_name noLLM)" || {
    echo "[FEHLER] Tag noLLM konnte nicht sicher ermittelt werden." >&2
    exit 1
}
''',
'''if ! NO_LLM_TAG_ID="$(pm_paperless_tag_id_by_name noLLM)"; then
    echo "[FEHLER] Paperless-Tag-Katalog konnte nicht sicher gelesen werden." >&2
    exit 1
fi
if [[ -n "$NO_LLM_TAG_ID" ]]; then
    echo "[INFO] Schutz-Tag noLLM gefunden: ID $NO_LLM_TAG_ID"
else
    echo "[WARNUNG] Tag noLLM fehlt; Gemini-Verarbeitung läuft ohne Tag-Filter weiter." >&2
fi
'''), (
'''    if jq -e --argjson tag_id "$NO_LLM_TAG_ID" \\
        '(.tags | index($tag_id)) != null' \\
        <<< "$document_json" >/dev/null; then
''',
'''    if [[ -n "$NO_LLM_TAG_ID" ]] && jq -e --argjson tag_id "$NO_LLM_TAG_ID" \\
        '(.tags | index($tag_id)) != null' \\
        <<< "$document_json" >/dev/null; then
''')]
}

updated = {}
for path, replacements in changes.items():
    content = path.read_text()
    for old, new in replacements:
        count = content.count(old)
        if count != 1:
            raise SystemExit(f'ABBRUCH: erwartete genau 1 Fundstelle in {path}, gefunden: {count}. Es wurde keine Datei geschrieben.')
        content = content.replace(old, new, 1)
    updated[path] = content

for path, content in updated.items():
    path.write_text(content)
    print(f'Geändert: {path}')
PY
bash -n paperless_metadata/scripts/01_analyze.sh
bash -n paperless_metadata/scripts/03_update_all_missing_gemini.sh
bash -n paperless_metadata/scripts/lib/paperless_api.sh
git diff --check
printf '\nSyntaxprüfung und git diff --check erfolgreich.\n'
