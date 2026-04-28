#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-}"
API_KEY="${API_KEY:-}"
MODEL="${MODEL:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/../../lib/image-source.sh"
source "${SCRIPT_DIR}/../../lib/openai-chat-completions-sse.sh"
source "${SCRIPT_DIR}/../../lib/thinking.sh"

# Set to a remote URL or a local file path
IMAGE="https://ts1.tc.mm.bing.net/th/id/OIP-C.0-YVnXaHj82gSvdAQXFMrgHaFb?rs=1&pid=ImgDetMain&o=7&rm=3"

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

# ── Handle local file or remote URL → base64 data URI ────────────────────────
prepare_image_data_url "$IMAGE"
IMAGE_URL_FILE="$(mktemp /tmp/openai_image_url_XXXXXX.txt)"
printf '%s' "$IMAGE_DATA_URL" > "$IMAGE_URL_FILE"

PAYLOAD_FILE="$(mktemp /tmp/chat_completions_payload_XXXXXX.json)"
RAW_STREAM_FILE="$(mktemp /tmp/chat_completions_stream_XXXXXX.log)"
HEADERS_FILE="$(mktemp /tmp/chat_completions_headers_XXXXXX.log)"
cleanup() {
  rm -f "$IMAGE_URL_FILE" "$PAYLOAD_FILE" "$RAW_STREAM_FILE" "$HEADERS_FILE"
}
trap cleanup EXIT

jq -n \
  --arg model "$MODEL" \
  --argjson thinking_overrides "$THINKING_OVERRIDES_JSON" \
  --rawfile image_url "$IMAGE_URL_FILE" \
  '
  ({
    model: $model,
    stream: true,
    stream_options: {
      include_usage: true
    },
    messages: [
      {
        role: "system",
        content: "You are a helpful assistant that can analyze images."
      },
      {
        role: "user",
        content: "Please read and describe the image at /tmp/photo.jpg"
      },
      {
        role: "assistant",
        content: null,
        tool_calls: [{
          id:   "call_readimg_001",
          type: "function",
          function: {
            name:      "read_image",
            arguments: "{\"image_path\": \"/tmp/photo.jpg\"}"
          }
        }]
      },
      {
        role: "user",
        content: [
          { type: "text",      text: "Successfully read image from /tmp/photo.jpg" },
          { type: "image_url", image_url: { url: $image_url } }
        ]
      }
    ]
  } + $thinking_overrides)
  ' > "$PAYLOAD_FILE"

echo "=== Request ==="
echo "Endpoint          : ${BASE_URL}/chat/completions"
echo "Model             : ${MODEL}"
echo "Image             : ${IMAGE_SOURCE_SUMMARY}"
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
