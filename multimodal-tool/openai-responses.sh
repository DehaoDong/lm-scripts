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
  -u, --url <url>          OpenAI-compatible API base URL, including the version prefix.
                           Example: https://api.openai.com/v1
  -k, --key <key>          API key used as the Bearer token.
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
  bash ${BASH_SOURCE[0]} -u https://api.openai.com/v1 -k sk-... -m gpt-4.1 -i ./image.jpg
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

openai_responses_sse_to_summary() {
  local raw_stream_file="${1:?raw stream file is required}"
  local stream_json=""

  stream_json="$(
    sed -n 's/^data: *//p' "$raw_stream_file" | sed '/^\[DONE\]$/d'
  )"

  if [[ -z "$stream_json" ]]; then
    echo "[error] No SSE data chunks were received." >&2
    return 1
  fi

  printf '%s\n' "$stream_json" | jq -s '
    reduce .[] as $event (
      {
        content: "",
        reasoning: "",
        refusal: "",
        usage: null,
        function_calls: {},
        error: null
      };

      if $event.type == "response.output_text.delta" then
        .content += ($event.delta // "")

      elif $event.type == "response.refusal.delta" then
        .refusal += ($event.delta // "")

      elif ($event.type | test("reasoning.*delta$")) then
        .reasoning += ($event.delta // "")

      elif $event.type == "response.function_call_arguments.delta" then
        .function_calls[$event.item_id] |= (
          (. // { call_id: null, name: null, arguments: "" })
          | .arguments += ($event.delta // "")
        )

      elif $event.type == "response.output_item.done" then
        if $event.item.type == "function_call" then
          .function_calls[($event.item.call_id // $event.item.id)] = {
            call_id: $event.item.call_id,
            name: $event.item.name,
            arguments: $event.item.arguments
          }
        else . end

      elif ($event.type == "response.completed" or $event.type == "response.failed") then
        .usage = ($event.response.usage // .usage) |
        .error = ($event.response.error // .error)

      elif $event.type == "error" then
        .error = $event

      else . end
    )
    | .function_calls = (.function_calls | to_entries | map(.value))
  '
}

openai_responses_assert_summary_ok() {
  local summary_json="${1:?summary json is required}"
  local error=""

  error="$(printf '%s\n' "$summary_json" | jq -r '.error // empty')"
  if [[ -n "$error" ]]; then
    echo "[error] API error:" >&2
    printf '%s\n' "$summary_json" | jq '.error' >&2
    return 1
  fi
}

openai_responses_print_aggregated_response() {
  local summary_json="${1:?summary json is required}"

  printf '%s\n' "$summary_json" | jq -r '
    .reasoning as $reasoning
    | .content as $content
    | if ($reasoning | length) > 0 then
        "<think>\n" + $reasoning + "\n</think>\n\n" + $content
      else
        $content
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
  --argjson extra_args "$EXTRA_ARGS" \
  --rawfile image_url "$IMAGE_URL_FILE" \
  '
  ({
    model: $model,
    stream: true,
    input: [
      {
        type: "message",
        role: "user",
        content: [
          { type: "input_text", text: "Please use the read_image tool to inspect /tmp/photo.jpg, then describe the image briefly." }
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
          { type: "input_text", text: "Successfully read image from /tmp/photo.jpg." },
          { type: "input_image", image_url: $image_url, detail: "auto" }
        ]
      }
    ]
  } + $extra_args)
  ' > "$PAYLOAD_FILE"

echo "=== Request ==="
echo "Endpoint          : ${BASE_URL}/responses"
echo "Model             : ${MODEL}"
echo "Image             : ${IMAGE_SOURCE_SUMMARY}"
echo "Extra Args        : ${EXTRA_ARGS}"
echo

echo "=== Raw Stream ==="
CURL_ARGS=(
  "${CURL_SKIP_SSL_ARGS[@]}"
  -sS
  -N
  -D "$HEADERS_FILE"
  "${BASE_URL}/responses"
  -H "Content-Type: application/json"
  -H "Authorization: Bearer ${API_KEY}"
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

SUMMARY_JSON="$(openai_responses_sse_to_summary "$RAW_STREAM_FILE")"
openai_responses_assert_summary_ok "$SUMMARY_JSON"

echo "=== Aggregated LLM Response ==="
openai_responses_print_aggregated_response "$SUMMARY_JSON"
echo
echo
