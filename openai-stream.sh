#!/usr/bin/env bash
set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
BASE_URL="${BASE_URL:-}"
API_KEY="${API_KEY:-}"
MODEL="${MODEL:-}"
SYSTEM_PROMPT="${SYSTEM_PROMPT:-You are a helpful assistant.}"
USER_PROMPT="${USER_PROMPT:-${*:-Tell me a short joke.}}"

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

# ── Build JSON payload (via jq for safe escaping) ────────────────────────────
PAYLOAD=$(mktemp /tmp/llm_payload_XXXXXX.json)
trap 'rm -f "$PAYLOAD"' EXIT

jq -n \
  --arg model "$MODEL" \
  --arg system_prompt "$SYSTEM_PROMPT" \
  --arg user_prompt "$USER_PROMPT" \
  '{
    model: $model,
    stream: true,
    messages: [
      {
        role: "system",
        content: $system_prompt
      },
      {
        role: "user",
        content: $user_prompt
      }
    ]
  }' > "$PAYLOAD"

# ── Print request summary ───────────────────────────────────────────────────
echo "=== Request ==="
echo "  Endpoint : ${BASE_URL}/chat/completions"
echo "  Model    : ${MODEL}"
echo "  Prompt   : ${USER_PROMPT}"
echo ""

# ── Call API and print raw SSE stream ───────────────────────────────────────
echo "=== Raw Stream Events ==="
curl -sN "${BASE_URL}/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${API_KEY}" \
  -d @"$PAYLOAD"
