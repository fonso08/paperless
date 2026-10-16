#!/usr/bin/env bash
# Gemini REST Provider; API-Key und Dokumentinhalt niemals protokollieren.
pm_gemini_classify() {
  [[ -n "${GEMINI_API_KEY:-}" ]] || {
    echo 'GEMINI_API_KEY fehlt' >&2
    return 1
  }

  local doc="$1" payload response text prompt http_code body
  prompt="$(cat "${PM_ROOT}/config/classification_prompt.txt")" || return 1

  payload="$(jq -n --arg prompt "$prompt" --argjson doc "$doc" \
    '{contents:[{parts:[{text:($prompt+"\n\nDokumentdaten:\n"+($doc|tojson))}]}],generationConfig:{responseMimeType:"application/json",temperature:0.1}}')" || return 1

  # HTTP-Status getrennt vom Antworttext erfassen.
  response="$(curl --silent --show-error --connect-timeout 10 \
    --max-time "${LLM_TIMEOUT_SECONDS}" \
    -w $'\n%{http_code}' \
    -H "x-goog-api-key: ${GEMINI_API_KEY}" \
    -H 'Content-Type: application/json' \
    --data-binary "$payload" \
    "https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODEL}:generateContent")" || {
      echo 'Gemini-Verbindungsfehler (curl)' >&2
      return 1
    }

  http_code="${response##*$'\n'}"
  body="${response%$'\n'*}"

  if [[ ! "$http_code" =~ ^2[0-9][0-9]$ ]]; then
    echo "Gemini HTTP-Fehler: $http_code" >&2
    # Nur die Google-Fehlermeldung ausgeben, nicht die Anfrage.
    jq -c '{error:{code:.error.code,status:.error.status,message:.error.message,details:.error.details}}' \
      <<< "$body" >&2 2>/dev/null || echo 'Google-Antwort konnte nicht als JSON gelesen werden.' >&2
    return 1
  fi

  text="$(jq -er '[.candidates[0].content.parts[]?.text] | join("") | select(length>0)' <<< "$body")" || {
    echo 'Gemini-Antwort enthält keinen auswertbaren Text.' >&2
    return 1
  }

  jq -e . <<< "$text"
}
