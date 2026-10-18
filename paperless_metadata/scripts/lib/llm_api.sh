#!/usr/bin/env bash
# Einheitliche Provider-Schnittstelle. stdout: validiertes Vorschlags-JSON.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

pm_llm_classify() {
  local document_json="$1" result checked

  case "$LLM_PROVIDER" in
    gemini)
      source "${PM_ROOT}/scripts/lib/providers/gemini.sh"
      result="$(pm_gemini_classify "$document_json")" || {
        echo "FEHLER: Gemini-Provider lieferte keine gültige Antwort." >&2
        return 1
      }
      ;;
    groq)
      source "${PM_ROOT}/scripts/lib/providers/groq.sh"
      result="$(pm_groq_classify "$document_json")" || return 1
      ;;
    openrouter)
      source "${PM_ROOT}/scripts/lib/providers/openrouter.sh"
      result="$(pm_openrouter_classify "$document_json")" || return 1
      ;;
    *)
      echo "Unbekannter Anbieter: $LLM_PROVIDER" >&2
      return 1
      ;;
  esac

  checked="$(jq -c '
    [
      if type != "object" then "Antwort ist kein JSON-Objekt" else empty end,
      if (.title != null and ((.title | type) != "string" or (.title | length) > 160)) then "title ungültig" else empty end,
      if ((.primary_tag | type) != "string" or (.primary_tag | length) == 0) then "primary_tag fehlt oder ist kein String" else empty end,
      if ((.additional_tags | type) != "array") then "additional_tags ist kein Array" else empty end,
      if (.correspondent != null and (.correspondent | type) != "string") then "correspondent ungültig" else empty end,
      if (.correspondent_suggestion != null and (.correspondent_suggestion | type) != "string") then "correspondent_suggestion ungültig" else empty end,
      if (.document_date != null and (.document_date | type) != "string") then "document_date ungültig" else empty end,
      if (.confidence | type) != "number" or .confidence < 0 or .confidence > 1 then "confidence ungültig" else empty end,
      if (.requires_review | type) != "boolean" then "requires_review ungültig" else empty end,
      if (.reason | type) != "string" then "reason ungültig" else empty end
    ]' <<< "$result")" || return 1

  if [[ "$checked" != "[]" ]]; then
    echo "FEHLER: Schema-Prüfung: $checked" >&2
    return 1
  fi

  checked="$(jq -c '{
    title: (.title // null),
    primary_tag: .primary_tag,
    additional_tags: .additional_tags,
    correspondent: (.correspondent // null),
    correspondent_suggestion: (.correspondent_suggestion // null),
    document_date: (.document_date // null),
    confidence: .confidence,
    requires_review: .requires_review,
    reason: .reason
  }' <<< "$result")" || return 1

  printf '%s\n' "$checked"
}
