#!/bin/bash
# ============================================================
# paperless_api.sh - Paperless-ngx API v10
# ============================================================
# Kapselt alle HTTP-Zugriffe auf Paperless.
#
# Getestetes Verhalten Paperless 3.2.0:
# POST /api/documents/post_document/
#   -> JSON-String mit UUID (Celery/Paperless task_id)
#
# GET /api/tasks/ liefert TaskSerializerV10.
# Ein Duplikat wird von Paperless als:
#   status = failure
#   result_data.duplicate_of = <Dokument-ID>
#   result_data.duplicate_in_trash = true|false
# erkannt.
#
# Dieser spezielle failure-Fall ist KEIN Fehler der Automation,
# sondern der normale DUPLICATE-Zustand.
# ============================================================

require_env "PAPERLESS_TOKEN"
require_command curl
require_command jq

paperless_api_url() {
    local path="$1"
    printf '%s/api/%s' "${PAPERLESS_URL%/}" "${path#/}"
}

paperless_curl() {
    curl -fsS \
        --connect-timeout 10 \
        --max-time 120 \
        -H "Authorization: Token ${PAPERLESS_TOKEN}" \
        -H "Accept: application/json" \
        "$@"
}

paperless_upload() {
    local file="$1"
    local response

    [[ -f "${file}" ]] || return 1

    response="$(
        python3 - "${file}" "$(paperless_api_url 'documents/post_document/')" <<'PYTHON'
import os
import sys
import requests

file_path = sys.argv[1]
url = sys.argv[2]

token = os.environ["PAPERLESS_TOKEN"]

with open(file_path, "rb") as f:
    response = requests.post(
        url,
        headers={
            "Authorization": f"Token {token}",
            "Accept": "application/json",
        },
        files={
            "document": (
                os.path.basename(file_path),
                f,
                "application/pdf",
            )
        },
        timeout=300,
    )

response.raise_for_status()
print(response.text)
PYTHON
    )" || return 1

    printf '%s\n' "${response}" \
        | jq -r 'if type == "string" then . else empty end'
}

paperless_task_by_uuid() {
    local task_uuid="$1"
    local page=1 response match

    # /api/tasks/ filter nach task_id ist in der konkreten API nicht
    # vorausgesetzt. Deshalb wird paginiert und die UUID exakt gesucht.
    while :; do
        response="$(paperless_curl "$(paperless_api_url "tasks/?page=${page}")")" || return 1

        match="$(printf '%s' "${response}" | jq -c --arg id "${task_uuid}" '.results[]? | select(.task_id == $id)' | head -n1)"
        if [[ -n "${match}" ]]; then
            printf '%s\n' "${match}"
            return 0
        fi

        if [[ "$(printf '%s' "${response}" | jq -r '.next // empty')" == "" ]]; then
            break
        fi
        page=$((page + 1))
    done

    return 1
}

paperless_task_status() {
    local task_uuid="$1"
    local task
    task="$(paperless_task_by_uuid "${task_uuid}")" || return 1
    printf '%s\n' "${task}" | jq -r '.status'
}

paperless_task_json() {
    local task_uuid="$1"
    paperless_task_by_uuid "${task_uuid}"
}

paperless_task_acknowledge() {
    local task_uuid="$1"
    local task_json
    local task_id

    task_json="$(paperless_task_json "${task_uuid}")" || return 1

    task_id="$(printf '%s\n' "${task_json}" | jq -r '.id // empty')"

    if [[ -z "${task_id}" || "${task_id}" == "null" ]]; then
        error "Paperless-Task ${task_uuid}: numerische Task-ID konnte nicht ermittelt werden."
        return 1
    fi

    paperless_curl \
        -X POST \
        -H "Content-Type: application/json" \
        --data "{\"tasks\":[${task_id}]}" \
        "$(paperless_api_url "tasks/acknowledge/")" \
        >/dev/null
}

paperless_task_result_data() {
    local task_uuid="$1"
    paperless_task_json "${task_uuid}" | jq -c '.result_data // {}'
}

paperless_task_duplicate_of() {
    local task_uuid="$1"
    paperless_task_json "${task_uuid}" | jq -r '.result_data.duplicate_of // empty'
}

paperless_task_duplicate_in_trash() {
    local task_uuid="$1"
    paperless_task_json "${task_uuid}" | jq -r '.result_data.duplicate_in_trash // false'
}

paperless_task_related_document_id() {
    local task_uuid="$1"
    paperless_task_json "${task_uuid}" | jq -r '.related_document_ids[0] // empty'
}

paperless_document_json() {
    local document_id="$1"
    paperless_curl "$(paperless_api_url "documents/${document_id}/")"
}

paperless_document_tags_json() {
    local document_id="$1"
    paperless_document_json "${document_id}" | jq -c '.tags // []'
}

paperless_document_checksum() {
    local document_id="$1"
    paperless_document_json "${document_id}" | jq -r '.checksum // empty'
}
