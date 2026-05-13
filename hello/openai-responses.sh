#!/usr/bin/env bash
set -euo pipefail

BASE_URL=""
API_KEY=""
MODEL=""
EXTRA_ARGS="{}"
CURL_SKIP_SSL_ARGS=()

print_help() {
  cat <<EOF
Usage:
  bash ${BASH_SOURCE[0]} -u <url> -k <key> -m <model> [-e <json>] [-s|--skip-ssl]

Options:
  -u, --url <url>          OpenAI-compatible API base URL, including the version prefix.
                           Example: https://api.openai.com/v1
  -k, --key <key>          API key used as the Bearer token.
  -m, --model <model>      Model name.
  -e, --extra-args <json>  Optional JSON object merged into the request body.
                           Example: '{"temperature":0}'
  -s, --skip-ssl           Skip TLS certificate verification.
  -h, --help               Show this help.

Examples:
  bash ${BASH_SOURCE[0]} -u https://api.openai.com/v1 -k sk-... -m gpt-4.1
  bash ${BASH_SOURCE[0]} --url http://localhost:10000/v1 --key dummy-key --model example-model --extra-args '{"temperature":0}' --skip-ssl
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

validate_extra_args() {
  if ! printf '%s\n' "$EXTRA_ARGS" | jq -e 'type == "object"' >/dev/null; then
    echo "[error] EXTRA_ARGS must be a JSON object string, for example: {\"temperature\":0}" >&2
    exit 1
  fi
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
validate_extra_args

PAYLOAD_FILE="$(mktemp /tmp/responses_payload_XXXXXX.json)"
RAW_STREAM_FILE="$(mktemp /tmp/responses_stream_XXXXXX.log)"
HEADERS_FILE="$(mktemp /tmp/responses_headers_XXXXXX.log)"
cleanup() {
  rm -f "$PAYLOAD_FILE" "$RAW_STREAM_FILE" "$HEADERS_FILE"
}
trap cleanup EXIT

jq -n \
  --arg model "$MODEL" \
  --argjson extra_args "$EXTRA_ARGS" \
  '
  ({
    model: $model,
    stream: true,
    input: [
      {
        role: "user",
        content: "Hello"
      }
    ]
  } + $extra_args)
  ' > "$PAYLOAD_FILE"

echo "=== Request ==="
echo "Endpoint          : ${BASE_URL}/responses"
echo "Model             : ${MODEL}"
echo "Extra Args        : ${EXTRA_ARGS}"
echo

echo "=== Raw Stream ==="
curl "${CURL_SKIP_SSL_ARGS[@]}" -sS -N \
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
