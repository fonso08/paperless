#!/usr/bin/env bash
# Einheitliche Provider-Schnittstelle. stdout: validiertes Vorschlags-JSON.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
pm_llm_classify() {
  local document_json="$1" result
  case "$LLM_PROVIDER" in
    gemini) source "${PM_ROOT}/scripts/lib/providers/gemini.sh"; result="$(pm_gemini_classify "$document_json")" || return 1 ;;
    groq) source "${PM_ROOT}/scripts/lib/providers/groq.sh"; result="$(pm_groq_classify "$document_json")" || return 1 ;;
    openrouter) source "${PM_ROOT}/scripts/lib/providers/openrouter.sh"; result="$(pm_openrouter_classify "$document_json")" || return 1 ;;
    *) echo "Unbekannter Anbieter: $LLM_PROVIDER" >&2; return 1 ;;
  esac
  jq -e '{primary_tag:(.primary_tag // null),additional_tags:(.additional_tags // []),correspondent:(.correspondent // null),correspondent_suggestion:(.correspondent_suggestion // null),document_date:(.document_date // null),confidence:(.confidence // 0),requires_review:(.requires_review // true),reason:(.reason // "")}
    | select((.additional_tags|type)=="array" and (.confidence|type)=="number" and .confidence>=0 and .confidence<=1 and (.requires_review|type)=="boolean")' <<< "$result"
}
