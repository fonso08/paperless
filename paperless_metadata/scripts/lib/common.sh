#!/usr/bin/env bash
# Gemeinsame Funktionen: sichere Konfiguration, Logging, Voraussetzungen.
PM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "${PM_ROOT}/config/metadata.conf"
PM_STATE="${PM_STATE:-/media/BlueDisc3/PAPERLESS/state/metadata}"
pm_require() { command -v "$1" >/dev/null 2>&1 || { printf 'Fehlt: %s\n' "$1" >&2; return 1; }; }
pm_init() {
  pm_require curl && pm_require jq && pm_require flock || return 1
  [[ -d "$BASE_DIR" ]] || { echo 'Projektpfad fehlt' >&2; return 1; }
  [[ -d "$LOG_DIR" && -w "$LOG_DIR" ]] || { echo "Logverzeichnis nicht verfügbar: $LOG_DIR" >&2; return 1; }
  mkdir -p "$PM_STATE/analysis" "$PM_STATE/proposals" "$PM_STATE/backups" "$PM_STATE/jobs"
}
pm_log() {
  local level="$1"; shift
  local msg; msg="$(date -Is) [$level] $*"
  printf '%s\n' "$msg" >&2
  printf '%s\n' "$msg" >> "$LOG_DIR/paperless-metadata.log"
}
pm_atomic_json() {
  local path="$1" tmp
  tmp="$(mktemp "${path}.tmp.XXXXXX")" || return 1
  if jq -e . > "$tmp"; then mv -f -- "$tmp" "$path"; else rm -f -- "$tmp"; return 1; fi
}
