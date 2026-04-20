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

RAW_RESPONSE_FILE="$(mktemp /tmp/openai_models_response_XXXXXX.json)"
HEADERS_FILE="$(mktemp /tmp/openai_models_headers_XXXXXX.log)"
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
  -H "Authorization: Bearer ${API_KEY}"
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
  def fmt_created:
    if .created == null then
      "-"
    else
      (.created | gmtime | strftime("%Y-%m-%dT%H:%M:%SZ"))
    end;

  .data // []
  | if length == 0 then
      "No models returned."
    else
      sort_by(.id)[]
      | [
          "ID                : \(.id // "-")",
          "Owned By          : \(.owned_by // "-")",
          "Created           : \(fmt_created)",
          "Object            : \(.object // "-")",
          ""
        ][]
    end
' "$RAW_RESPONSE_FILE"

echo "=== Metadata ==="
jq -r '
  [
    "Object            : \(.object // "-")",
    "Model Count       : \((.data // []) | length)"
  ][]
' "$RAW_RESPONSE_FILE"
