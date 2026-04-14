#!/usr/bin/env bash
set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
BASE_URL="${BASE_URL:-}"
API_KEY="${API_KEY:-}"
MODEL="${MODEL:-}"
# Set to a remote URL or a local file path (auto base64-encoded)
IMAGE_URL="https://ts1.tc.mm.bing.net/th/id/OIP-C.0-YVnXaHj82gSvdAQXFMrgHaFb?rs=1&pid=ImgDetMain&o=7&rm=3"

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

# ── Handle local file → base64 data URI ──────────────────────────────────────
if [[ -f "$IMAGE_URL" ]]; then
  MIME=$(file -b --mime-type "$IMAGE_URL")
  IMAGE_URL="data:${MIME};base64,$(base64 -w0 "$IMAGE_URL")"
  echo "[info] Encoded local file as data URI (${MIME})"
fi

# ── Build JSON payload (via jq for safe escaping) ────────────────────────────
PAYLOAD=$(mktemp /tmp/llm_payload_XXXXXX.json)
trap 'rm -f "$PAYLOAD"' EXIT

jq -n \
  --arg model "$MODEL" \
  --arg image_url "$IMAGE_URL" \
  '{
    model: $model,
    stream: true,
    instructions: "You are a helpful assistant that can analyze images.",
    input: [
      {
        role: "user",
        content: [
          { type: "input_text", text: "Please read and describe the image at /tmp/photo.jpg" },
          { type: "input_image", image_url: $image_url, detail: "auto" }
        ]
      }
    ]
  }' > "$PAYLOAD"

# ── Print request summary ───────────────────────────────────────────────────
echo "=== Request ==="
echo "  Endpoint : ${BASE_URL}/responses"
echo "  Model    : ${MODEL}"
echo "  Image    : $(if [[ $IMAGE_URL == data:* ]]; then echo '(base64 local file)'; else echo "$IMAGE_URL"; fi)"
echo ""

# ── Call API (stream SSE) ───────────────────────────────────────────────────
echo "=== Response ==="
curl -sN "${BASE_URL}/responses" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${API_KEY}" \
  -d @"$PAYLOAD" | while IFS= read -r line; do
  # SSE lines look like "data: {...}" or "data: [DONE]"
  [[ "$line" != data:* ]] && continue
  payload="${line#data }"  # strip "data " prefix
  payload="${line#data: }" # strip "data: " prefix
  [[ "$payload" == "[DONE]" ]] && break
  # Extract the delta content token
  token=$(echo "$payload" | jq -r 'if .type == "response.output_text.delta" then .delta else empty end' 2>/dev/null) && printf '%s' "$token"
done
echo
