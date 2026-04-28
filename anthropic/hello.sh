#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-}"
API_KEY="${API_KEY:-}"
MODEL="${MODEL:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/../lib/anthropic-messages-sse.sh"
source "${SCRIPT_DIR}/../lib/thinking.sh"

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
require_env MODEL

THINKING_OVERRIDES_JSON="$(thinking_overrides_json)"

PAYLOAD_FILE="$(mktemp /tmp/anthropic_messages_payload_XXXXXX.json)"
RAW_STREAM_FILE="$(mktemp /tmp/anthropic_messages_stream_XXXXXX.log)"
HEADERS_FILE="$(mktemp /tmp/anthropic_messages_headers_XXXXXX.log)"
cleanup() {
  rm -f "$PAYLOAD_FILE" "$RAW_STREAM_FILE" "$HEADERS_FILE"
}
trap cleanup EXIT

jq -n \
  --arg model "$MODEL" \
  --argjson thinking_overrides "$THINKING_OVERRIDES_JSON" \
  '({
    model: $model,
    max_tokens: 1024,
    stream: true,
    system: "You are a helpful assistant.",
    messages: [
      {
        role: "user",
        content: "Hello"
      }
    ]
  } + $thinking_overrides)' > "$PAYLOAD_FILE"

echo "=== Request ==="
echo "Endpoint          : ${BASE_URL}/messages"
echo "Model             : ${MODEL}"
echo "Thinking          : $(thinking_status_label)"
echo

echo "=== Raw Stream ==="
curl -sS -N \
  -D "$HEADERS_FILE" \
  -o >(tee "$RAW_STREAM_FILE") \
  "${BASE_URL}/messages" \
  -H "Content-Type: application/json" \
  -H "x-api-key: ${API_KEY}" \
  -H "anthropic-version: 2023-06-01" \
  -d @"$PAYLOAD_FILE"
echo
echo

HTTP_CODE="$(awk 'toupper($1) ~ /^HTTP/ { code = $2 } END { print code }' "$HEADERS_FILE")"

if [[ ! "$HTTP_CODE" =~ ^2 ]]; then
  echo "[error] HTTP ${HTTP_CODE}" >&2
  exit 1
fi

SUMMARY_JSON="$(anthropic_messages_sse_to_summary "$RAW_STREAM_FILE")"
anthropic_messages_assert_summary_ok "$SUMMARY_JSON"

echo "=== Aggregated LLM Response ==="
anthropic_messages_print_aggregated_response "$SUMMARY_JSON"
echo
echo

echo "=== Metadata ==="
anthropic_messages_print_metadata "$SUMMARY_JSON"
echo

echo "=== Usage ==="
anthropic_messages_print_usage "$SUMMARY_JSON"
echo

echo "=== Tool Uses ==="
anthropic_messages_print_tool_uses "$SUMMARY_JSON"
