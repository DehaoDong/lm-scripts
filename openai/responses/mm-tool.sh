#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-}"
API_KEY="${API_KEY:-}"
MODEL="${MODEL:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/../../lib/image-source.sh"
source "${SCRIPT_DIR}/../../lib/openai-responses-sse.sh"
source "${SCRIPT_DIR}/../../lib/thinking.sh"

# Set to a remote URL or a local file path
IMAGE="resources/Sydney-Opera-House.jpg"

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

PAYLOAD_FILE="$(mktemp /tmp/responses_payload_XXXXXX.json)"
RAW_STREAM_FILE="$(mktemp /tmp/responses_stream_XXXXXX.log)"
HEADERS_FILE="$(mktemp /tmp/responses_headers_XXXXXX.log)"
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
    instructions: "You are a helpful assistant that can analyze images.",
    input: [
      {
        type: "message",
        role: "user",
        content: [
          { type: "input_text", text: "Please read and describe the image at /tmp/photo.jpg" }
        ]
      },
      {
        type: "function_call",
        call_id: "call_readimg_001",
        name: "read_image",
        arguments: "{\"image_path\":\"/tmp/photo.jpg\"}"
      },
      {
        type: "function_call_output",
        call_id: "call_readimg_001",
        output: [
          { type: "input_text", text: "Successfully read image from /tmp/photo.jpg" },
          { type: "input_image", image_url: $image_url, detail: "auto" }
        ]
      }
    ]
  } + $thinking_overrides)
  ' > "$PAYLOAD_FILE"

echo "=== Request ==="
echo "Endpoint          : ${BASE_URL}/responses"
echo "Model             : ${MODEL}"
echo "Image             : ${IMAGE_SOURCE_SUMMARY}"
echo "Thinking          : $(thinking_status_label)"
echo

echo "=== Raw Stream ==="
curl -sS -N \
  -D "$HEADERS_FILE" \
  -o >(tee "$RAW_STREAM_FILE") \
  "${BASE_URL}/responses" \
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

SUMMARY_JSON="$(openai_responses_sse_to_summary "$RAW_STREAM_FILE")"
openai_responses_assert_summary_ok "$SUMMARY_JSON"

echo "=== Aggregated LLM Response ==="
openai_responses_print_aggregated_response "$SUMMARY_JSON"
echo
echo

echo "=== Metadata ==="
openai_responses_print_metadata "$SUMMARY_JSON"
echo

echo "=== Usage ==="
openai_responses_print_usage "$SUMMARY_JSON"
echo

echo "=== Function Calls ==="
openai_responses_print_function_calls "$SUMMARY_JSON"
