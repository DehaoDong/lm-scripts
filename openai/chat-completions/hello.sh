#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-}"
API_KEY="${API_KEY:-}"
MODEL="${MODEL:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/../../lib/openai-chat-completions-sse.sh"
source "${SCRIPT_DIR}/../../lib/thinking.sh"

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

PAYLOAD_FILE="$(mktemp /tmp/chat_completions_payload_XXXXXX.json)"
RAW_STREAM_FILE="$(mktemp /tmp/chat_completions_stream_XXXXXX.log)"
HEADERS_FILE="$(mktemp /tmp/chat_completions_headers_XXXXXX.log)"
cleanup() {
  rm -f "$PAYLOAD_FILE" "$RAW_STREAM_FILE" "$HEADERS_FILE"
}
trap cleanup EXIT

jq -n \
  --arg model "$MODEL" \
  --argjson thinking_overrides "$THINKING_OVERRIDES_JSON" \
  '
  ({
    model: $model,
    stream: true,
    stream_options: {
      include_usage: true
    },
    messages: [
      {
        role: "user",
        content: "Hello"
      }
    ]
  } + $thinking_overrides)
  ' > "$PAYLOAD_FILE"

echo "=== Request ==="
echo "Endpoint          : ${BASE_URL}/chat/completions"
echo "Model             : ${MODEL}"
echo "Thinking          : $(thinking_status_label)"
echo

echo "=== Raw Stream ==="
curl -sS -N \
  -D "$HEADERS_FILE" \
  -o >(tee "$RAW_STREAM_FILE") \
  "${BASE_URL}/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${API_KEY}" \
  -d @"$PAYLOAD_FILE"
echo
echo

HTTP_CODE="$(awk 'toupper($1) ~ /^HTTP/ { code = $2 } END { print code }' "$HEADERS_FILE")"

if [[ ! "$HTTP_CODE" =~ ^2 ]]; then
  echo "[error] HTTP ${HTTP_CODE}" >&2
  exit 1
fi

SUMMARY_JSON="$(openai_chat_completions_sse_to_summary "$RAW_STREAM_FILE")"

echo "=== Aggregated LLM Response ==="
openai_chat_completions_print_aggregated_response "$SUMMARY_JSON"
echo
echo

echo "=== Metadata ==="
openai_chat_completions_print_metadata "$SUMMARY_JSON"
echo

echo "=== Usage ==="
openai_chat_completions_print_usage "$SUMMARY_JSON"
echo

echo "=== Tool Calls ==="
openai_chat_completions_print_tool_calls "$SUMMARY_JSON"
