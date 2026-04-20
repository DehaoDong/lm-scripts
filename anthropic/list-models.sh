#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-}"
API_KEY="${API_KEY:-}"

require_bin() {
  local bin="$1"
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "[error] Missing dependency: $bin" >&2
    exit 1
  fi
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "[error] ${name} is not set" >&2
    exit 1
  fi
}

require_bin curl
require_bin jq
require_env BASE_URL
require_env API_KEY

RAW_RESPONSE_FILE="$(mktemp /tmp/anthropic_models_response_XXXXXX.json)"
HEADERS_FILE="$(mktemp /tmp/anthropic_models_headers_XXXXXX.log)"
cleanup() {
  rm -f "$RAW_RESPONSE_FILE" "$HEADERS_FILE"
}
trap cleanup EXIT

echo "=== Request ==="
echo "Endpoint          : ${BASE_URL}/models"
echo

echo "=== Raw Response ==="
curl -sS \
  -D "$HEADERS_FILE" \
  -o >(tee "$RAW_RESPONSE_FILE") \
  "${BASE_URL}/models" \
  -H "x-api-key: ${API_KEY}" \
  -H "anthropic-version: 2023-06-01"
echo
echo

HTTP_CODE="$(awk 'toupper($1) ~ /^HTTP/ { code = $2 } END { print code }' "$HEADERS_FILE")"

if [[ ! "$HTTP_CODE" =~ ^2 ]]; then
  echo "[error] HTTP ${HTTP_CODE}" >&2
  exit 1
fi

jq -e '.' "$RAW_RESPONSE_FILE" >/dev/null

echo "=== Models ==="
jq -r '
  .data // []
  | if length == 0 then
      "No models returned."
    else
      .[]
      | [
          "ID                : \(.id // "-")",
          "Display Name      : \(.display_name // "-")",
          "Created At        : \(.created_at // "-")",
          "Type              : \(.type // "-")",
          ""
        ][]
    end
' "$RAW_RESPONSE_FILE"

echo "=== Metadata ==="
jq -r '
  [
    "Model Count       : \((.data // []) | length)",
    "First ID          : \(.first_id // "-")",
    "Last ID           : \(.last_id // "-")",
    "Has More          : \(.has_more // false)"
  ][]
' "$RAW_RESPONSE_FILE"
