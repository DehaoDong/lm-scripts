#!/usr/bin/env bash
set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
BASE_URL="${BASE_URL:-}"
API_KEY="${API_KEY:-}"
MODEL="${MODEL:-}"

# Set to a remote URL or a local file path (auto base64-encoded)
IMAGE_URL="https://ts2.tc.mm.bing.net/th/id/OIP-C.t5-jvEoV-rIvVITQKV02jQHaEo?rs=1&pid=ImgDetMain&o=7&rm=3"

if [[ -z "$BASE_URL" ]]; then
  echo "[error] BASE_URL is not set" >&2
  exit 1
fi

if [[ -z "$API_KEY" ]]; then
  echo "[error] API_KEY is not set" >&2
  exit 1
fi

if [[ -z "$MODEL" ]]; then
  echo "[error] MODEL is not set" >&2
  exit 1
fi

# ── Handle local file or remote URL → base64 ─────────────────────────────────
if [[ -f "$IMAGE_URL" ]]; then
  image_media_type=$(file -b --mime-type "$IMAGE_URL")
  image_data=$(base64 -w0 "$IMAGE_URL")
  echo "[info] Encoded local file as base64 (${image_media_type})"
else
  echo "[info] Downloading remote image for base64 encoding..."
  tmp_img=$(mktemp /tmp/llm_img_XXXXXX)
  curl -sL "$IMAGE_URL" -o "$tmp_img"
  image_media_type=$(file -b --mime-type "$tmp_img")
  image_data=$(base64 -w0 "$tmp_img")
  rm -f "$tmp_img"
  echo "[info] Downloaded and encoded (${image_media_type})"
fi

# ── Build JSON payload (via jq for safe escaping) ────────────────────────────
# Mimics an agent conversation:
#   1. User asks to read an image
#   2. Assistant responds with a tool_call to read_image
#   3. Tool result returns the image content
#   4. LLM is expected to describe the image
PAYLOAD=$(mktemp /tmp/llm_payload_XXXXXX.json)
trap 'rm -f "$PAYLOAD"' EXIT

jq -n \
  --arg model        "$MODEL" \
  --arg image_media  "$image_media_type" \
  --arg image_data   "$image_data" \
  '{
    model: $model,
    max_tokens: 4096,
    stream: true,
    system: "You are a helpful assistant that can analyze images.",
    tools: [
      {
        name: "read_image",
        description: "Read an image file from the given path and return its content.",
        input_schema: {
          type: "object",
          properties: {
            image_path: { type: "string", description: "Path to the image file" }
          },
          required: ["image_path"]
        }
      }
    ],
    messages: [
      {
        role: "user",
        content: "Please read and describe the image at /tmp/photo.jpg"
      },
      {
        role: "assistant",
        content: [
          {
            type: "tool_use",
            id: "toolu_readimg_001",
            name: "read_image",
            input: { image_path: "/tmp/photo.jpg" }
          }
        ]
      },
      {
        role: "user",
        content: [
          {
            type: "tool_result",
            tool_use_id: "toolu_readimg_001",
            content: [
              { type: "text", text: "Successfully read image from /tmp/photo.jpg" },
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
      }
    ]
  }' > "$PAYLOAD"

# ── Print request summary ───────────────────────────────────────────────────
echo "=== Request ==="
echo "  Endpoint : ${BASE_URL}/messages"
echo "  Model    : ${MODEL}"
echo "  Image    : $(if [[ -f "$IMAGE_URL" ]]; then echo '(base64 local file)'; else echo "$IMAGE_URL (downloaded & base64)"; fi)"
echo ""

# ── Call API (stream SSE) ───────────────────────────────────────────────────
echo "=== Response ==="
curl -sN "${BASE_URL}/messages" \
  -H "Content-Type: application/json" \
  -H "x-api-key: ${API_KEY}" \
  -H "anthropic-version: 2023-06-01" \
  -d @"$PAYLOAD" | while IFS= read -r line; do
  # Anthropic SSE format: "event: ..." followed by "data: {...}" or "data:{...}"
  [[ "$line" != data:* ]] && continue
  payload="${line#data:}"
  # strip optional leading space
  payload="${payload# }"
  # Extract the delta text from content_block_delta events
  token=$(echo "$payload" | jq -r '
    if .type == "content_block_delta" and .delta.type == "text_delta" then
      .delta.text
    else
      empty
    end
  ' 2>/dev/null) && printf '%s' "$token"
done
echo
