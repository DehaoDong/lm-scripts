#!/usr/bin/env bash
set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
BASE_URL="${BASE_URL:-}"
API_KEY="${API_KEY:-}"
MODEL="${MODEL:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/../lib/image-source.sh"
source "${SCRIPT_DIR}/../lib/anthropic-messages-sse.sh"
source "${SCRIPT_DIR}/../lib/thinking.sh"

# Set to a remote URL or a local file path
IMAGE="https://ts2.tc.mm.bing.net/th/id/OIP-C.t5-jvEoV-rIvVITQKV02jQHaEo?rs=1&pid=ImgDetMain&o=7&rm=3"

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

# ── Handle local file or remote URL → base64 ─────────────────────────────────
prepare_image_base64_parts "$IMAGE"
IMAGE_DATA_FILE="$(mktemp /tmp/anthropic_image_data_XXXXXX.txt)"
printf '%s' "$IMAGE_BASE64_DATA" > "$IMAGE_DATA_FILE"

# ── Build JSON payload (via jq for safe escaping) ────────────────────────────
PAYLOAD_FILE="$(mktemp /tmp/anthropic_messages_payload_XXXXXX.json)"
RAW_STREAM_FILE="$(mktemp /tmp/anthropic_messages_stream_XXXXXX.log)"
HEADERS_FILE="$(mktemp /tmp/anthropic_messages_headers_XXXXXX.log)"
cleanup() {
  rm -f "$IMAGE_DATA_FILE" "$PAYLOAD_FILE" "$RAW_STREAM_FILE" "$HEADERS_FILE"
}
trap cleanup EXIT

jq -n \
  --arg model       "$MODEL" \
  --argjson thinking_overrides "$THINKING_OVERRIDES_JSON" \
  --arg image_media "$IMAGE_MEDIA_TYPE" \
  --rawfile image_data "$IMAGE_DATA_FILE" \
  '({
    model: $model,
    max_tokens: 4096,
    stream: true,
    system: "You are a helpful assistant that can analyze images.",
    messages: [
      {
        role: "user",
        content: [
          { type: "text", text: "Please read and describe the image at /tmp/photo.jpg" },
          {
            type: "image",
            source: {
              type: "base64",
              media_type: $image_media,
              data: $image_data
            }
          }
        ]
      }
    ]
  } + $thinking_overrides)' > "$PAYLOAD_FILE"

# ── Print request summary ───────────────────────────────────────────────────
echo "=== Request ==="
echo "Endpoint          : ${BASE_URL}/messages"
echo "Model             : ${MODEL}"
echo "Image             : ${IMAGE_SOURCE_SUMMARY}"
echo "Thinking          : $(thinking_status_label)"
echo

# ── Call API (stream SSE) ───────────────────────────────────────────────────
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
echo
