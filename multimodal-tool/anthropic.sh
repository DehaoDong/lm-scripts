#!/usr/bin/env bash
set -euo pipefail

BASE_URL=""
API_KEY=""
MODEL=""
IMAGE=""
EXTRA_ARGS="{}"
CURL_SKIP_SSL_ARGS=()

print_help() {
  cat <<EOF
Usage:
  bash ${BASH_SOURCE[0]} -u <url> -k <key> -m <model> -i <image> [-e <json>] [-s|--skip-ssl]

Options:
  -u, --url <url>          Anthropic API base URL, including the version prefix.
                           Example: https://api.anthropic.com/v1
  -k, --key <key>          Anthropic API key.
  -m, --model <model>      Model name.
  -i, --image <image>      Local file path or http(s) URL.
  -e, --extra-args <json>  Optional JSON object merged into the request body.
                           Example: '{"temperature":0}'
  -s, --skip-ssl           Skip TLS certificate verification.
  -h, --help               Show this help.

Notes:
  Quote remote image URLs that contain shell metacharacters such as '&', '?', or '#'.
  Otherwise the shell may run this script in the background before the full URL is passed.

Examples:
  bash ${BASH_SOURCE[0]} -u https://api.anthropic.com/v1 -k sk-ant-... -m claude-sonnet-4-0 -i ./image.jpg
  bash ${BASH_SOURCE[0]} --url http://localhost:10000/v1 --key dummy-key --model example-model --image 'https://example.com/image.jpg?width=512&height=512' --extra-args '{"temperature":0}' --skip-ssl
EOF
}

if [[ $# -eq 0 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  print_help
  exit 0
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    -u|--url)
      BASE_URL="${2:-}"
      shift 2
      ;;
    -k|--key)
      API_KEY="${2:-}"
      shift 2
      ;;
    -m|--model)
      MODEL="${2:-}"
      shift 2
      ;;
    -i|--image)
      IMAGE="${2:-}"
      shift 2
      ;;
    -e|--extra-args)
      EXTRA_ARGS="${2:-}"
      shift 2
      ;;
    -s|--skip-ssl)
      CURL_SKIP_SSL_ARGS=(--insecure)
      shift
      ;;
    -h|--help)
      print_help
      exit 0
      ;;
    *)
      echo "[error] Unknown argument: $1" >&2
      echo >&2
      print_help >&2
      exit 1
      ;;
  esac
done

require_bin() {
  local bin="$1"
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "[error] Missing dependency: $bin" >&2
    exit 1
  fi
}

require_arg() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "[error] Missing required argument: ${name}" >&2
    exit 1
  fi
}

ensure_foreground_job() {
  local shell_tpgid=""
  local script_pgid=""

  if [[ ! -t 0 || ! -t 1 ]]; then
    return 0
  fi

  if ! command -v ps >/dev/null 2>&1; then
    return 0
  fi

  shell_tpgid="$(ps -o tpgid= -p "$$" | tr -d '[:space:]')"
  script_pgid="$(ps -o pgid= -p "$$" | tr -d '[:space:]')"

  if [[ -n "$shell_tpgid" && -n "$script_pgid" && "$shell_tpgid" != "$script_pgid" ]]; then
    echo "[error] This script is running as a background job." >&2
    echo "[hint] If your image URL contains '&', quote it: --image 'https://example.com/image.jpg?x=1&y=2'" >&2
    exit 1
  fi
}

validate_extra_args() {
  if ! printf '%s\n' "$EXTRA_ARGS" | jq -e 'type == "object"' >/dev/null; then
    echo "[error] EXTRA_ARGS must be a JSON object string, for example: {\"temperature\":0}" >&2
    exit 1
  fi
}

prepare_image_data_url() {
  local image_ref="${1:?image reference is required}"
  local mime=""
  local tmp_img=""

  require_bin curl
  require_bin file
  require_bin base64

  if [[ -f "$image_ref" ]]; then
    mime="$(file -b --mime-type "$image_ref")"
    IMAGE_DATA_URL="data:${mime};base64,$(base64 -w0 "$image_ref")"
    IMAGE_SOURCE_SUMMARY="${image_ref} (base64 local file)"
    echo "[info] Encoded local file as data URI (${mime})"
    return 0
  fi

  if [[ "$image_ref" =~ ^https?:// ]]; then
    echo "[info] Downloading remote image for base64 encoding..."
    tmp_img="$(mktemp /tmp/llm_img_XXXXXX)"
    if ! curl "${CURL_SKIP_SSL_ARGS[@]}" -fsSL "$image_ref" -o "$tmp_img"; then
      rm -f "$tmp_img"
      echo "[error] Failed to download remote image: $image_ref" >&2
      return 1
    fi

    mime="$(file -b --mime-type "$tmp_img")"
    IMAGE_DATA_URL="data:${mime};base64,$(base64 -w0 "$tmp_img")"
    IMAGE_SOURCE_SUMMARY="${image_ref} (downloaded and base64)"
    rm -f "$tmp_img"
    echo "[info] Downloaded and encoded (${mime})"
    return 0
  fi

  echo "[error] IMAGE must be a local file path or remote http(s) URL" >&2
  return 1
}

prepare_image_base64_parts() {
  local rest=""

  prepare_image_data_url "$1"

  rest="${IMAGE_DATA_URL#data:}"
  IMAGE_MEDIA_TYPE="${rest%%;base64,*}"
  IMAGE_BASE64_DATA="${rest#*;base64,}"

  if [[ -z "$IMAGE_MEDIA_TYPE" || "$IMAGE_BASE64_DATA" == "$rest" ]]; then
    echo "[error] Failed to parse generated base64 image payload" >&2
    return 1
  fi
}

anthropic_messages_sse_to_summary() {
  local raw_stream_file="${1:?raw stream file is required}"
  local stream_json=""

  stream_json="$(
    sed -n 's/^data: *//p' "$raw_stream_file" | sed '/^[[:space:]]*$/d'
  )"

  if [[ -z "$stream_json" ]]; then
    echo "[error] No SSE data chunks were received." >&2
    return 1
  fi

  printf '%s\n' "$stream_json" | jq -s '
    reduce .[] as $event (
      {
        text: "",
        thinking: "",
        usage: null,
        tool_uses: {},
        error: null
      };

      if $event.type == "message_start" then
        .usage = ($event.message.usage // .usage)

      elif $event.type == "content_block_start" then
        if ($event.content_block.type // null) == "tool_use" then
          .tool_uses[($event.index | tostring)] = (
            (.tool_uses[($event.index | tostring)] // {
              id: null,
              name: null,
              input_json: ""
            })
            | .id = ($event.content_block.id // .id)
            | .name = ($event.content_block.name // .name)
          )
        else
          .
        end

      elif $event.type == "content_block_delta" then
        if $event.delta.type == "text_delta" then
          .text += ($event.delta.text // "")
        elif $event.delta.type == "thinking_delta" then
          .thinking += ($event.delta.thinking // "")
        elif $event.delta.type == "input_json_delta" then
          .tool_uses[($event.index | tostring)] = (
            (.tool_uses[($event.index | tostring)] // {
              id: null,
              name: null,
              input_json: ""
            })
            | .input_json += ($event.delta.partial_json // "")
          )
        else
          .
        end

      elif $event.type == "message_delta" then
        .usage = ($event.usage // .usage)

      elif $event.type == "error" then
        .error = $event.error

      else
        .
      end
    )
    | .tool_uses = (
        .tool_uses
        | to_entries
        | sort_by(.key | tonumber)
        | map(
            .value
            | .input = (
                if (.input_json | length) > 0 then
                  (.input_json | fromjson? // .input_json)
                else
                  null
                end
              )
            | del(.input_json)
          )
      )
  '
}

anthropic_messages_assert_summary_ok() {
  local summary_json="${1:?summary json is required}"

  if [[ "$(printf '%s\n' "$summary_json" | jq -r '.error != null')" == "true" ]]; then
    echo "[error] Stream contained an Anthropic error event:" >&2
    printf '%s\n' "$summary_json" | jq '.error' >&2
    return 1
  fi
}

anthropic_messages_print_aggregated_response() {
  local summary_json="${1:?summary json is required}"

  printf '%s\n' "$summary_json" | jq -r '
    .thinking as $thinking
    | .text as $text
    | if ($thinking | length) > 0 then
        "<think>\n" + $thinking + "\n</think>\n\n" + $text
      else
        $text
      end
  '
}


require_bin curl
require_bin jq
require_arg BASE_URL
require_arg API_KEY
require_arg MODEL
require_arg IMAGE
ensure_foreground_job
validate_extra_args

# ── Handle local file or remote URL → base64 ─────────────────────────────────
prepare_image_base64_parts "$IMAGE"
IMAGE_DATA_FILE="$(mktemp /tmp/anthropic_image_data_XXXXXX.txt)"
printf '%s' "$IMAGE_BASE64_DATA" > "$IMAGE_DATA_FILE"

# ── Build JSON payload (via jq for safe escaping) ────────────────────────────
# Mimics an agent conversation:
#   1. User asks to read an image
#   2. Assistant responds with a tool_call to read_image
#   3. Tool result returns the image content
#   4. LLM is expected to describe the image
PAYLOAD_FILE="$(mktemp /tmp/anthropic_messages_payload_XXXXXX.json)"
RAW_STREAM_FILE="$(mktemp /tmp/anthropic_messages_stream_XXXXXX.log)"
HEADERS_FILE="$(mktemp /tmp/anthropic_messages_headers_XXXXXX.log)"
cleanup() {
  rm -f "$IMAGE_DATA_FILE" "$PAYLOAD_FILE" "$RAW_STREAM_FILE" "$HEADERS_FILE"
}
trap cleanup EXIT

jq -n \
  --arg model        "$MODEL" \
  --argjson extra_args "$EXTRA_ARGS" \
  --arg image_media  "$IMAGE_MEDIA_TYPE" \
  --rawfile image_data "$IMAGE_DATA_FILE" \
  '({
    model: $model,
    max_tokens: 4096,
    stream: true,
    messages: [
      {
        role: "user",
        content: "Please use the read_image tool to inspect /tmp/photo.jpg, then describe the image briefly."
      },
      {
        role: "assistant",
        content: [
          {
            type: "tool_use",
            id: "toolu_readimg_001",
            name: "read_image",
            input: {
              image_path: "/tmp/photo.jpg"
            }
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
              {
                type: "text",
                text: "Successfully read image from /tmp/photo.jpg."
              },
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
  } + $extra_args)' > "$PAYLOAD_FILE"

# ── Print request summary ───────────────────────────────────────────────────
echo "=== Request ==="
echo "Endpoint          : ${BASE_URL}/messages"
echo "Model             : ${MODEL}"
echo "Image             : ${IMAGE_SOURCE_SUMMARY}"
echo "Extra Args        : ${EXTRA_ARGS}"
echo

# ── Call API (stream SSE) ───────────────────────────────────────────────────
echo "=== Raw Stream ==="
CURL_ARGS=(
  "${CURL_SKIP_SSL_ARGS[@]}"
  -sS
  -N
  -D "$HEADERS_FILE"
  "${BASE_URL}/messages"
  -H "Content-Type: application/json"
  -H "x-api-key: ${API_KEY}"
  -H "anthropic-version: 2023-06-01"
  -d @"$PAYLOAD_FILE"
)
curl -o >(tee "$RAW_STREAM_FILE") "${CURL_ARGS[@]}"
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
