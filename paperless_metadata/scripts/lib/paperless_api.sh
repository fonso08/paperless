#!/usr/bin/env bash
# Nur GET: Paperless-Metadaten lesen; keine Änderungen an Paperless.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
pm_paperless_get() {
  [[ -n "${PAPERLESS_TOKEN:-}" ]] || { echo 'PAPERLESS_TOKEN fehlt' >&2; return 1; }
  local endpoint="$1"
  [[ "$endpoint" == /api/* ]] || return 1
  curl --fail-with-body --silent --show-error --connect-timeout 10 --max-time 120 \
    -H "Authorization: Token ${PAPERLESS_TOKEN}" \
    -H "Accept: application/json; version=${PAPERLESS_API_VERSION}" \
    "${PAPERLESS_URL%/}${endpoint}"
}
pm_paperless_all_ids() {
  local page=1 body next
  while :; do
    body="$(pm_paperless_get "/api/documents/?page=${page}&page_size=100")" || return 1
    jq -r '.results[]?.id' <<< "$body" || return 1
    next="$(jq -r '.next // empty' <<< "$body")"
    [[ -n "$next" ]] || break
    ((page++))
  done
}
pm_paperless_document() { [[ "$1" =~ ^[0-9]+$ ]] && pm_paperless_get "/api/documents/$1/"; }
pm_paperless_catalog() {
  local resource="$1" page=1 body next tmp
  case "$resource" in tags|correspondents|document_types) ;; *) return 1;; esac
  tmp="$(mktemp)" || return 1
  echo '[]' > "$tmp"
  while :; do
    body="$(pm_paperless_get "/api/${resource}/?page=${page}&page_size=100")" || { rm -f "$tmp"; return 1; }
    jq -n --slurpfile old "$tmp" --argjson page "$body" '$old[0] + ($page.results // [])' > "${tmp}.next" || { rm -f "$tmp" "${tmp}.next"; return 1; }
    mv "${tmp}.next" "$tmp"
    next="$(jq -r '.next // empty' <<< "$body")"
    [[ -n "$next" ]] || break
    ((page++))
  done
  cat "$tmp"; rm -f "$tmp"
}
