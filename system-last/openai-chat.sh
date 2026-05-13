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

openai_chat_completions_sse_to_summary() {
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
    def as_text:
      if . == null then ""
      elif type == "string" then .
      elif type == "array" then
        [
          .[] |
          if type == "string" then .
          elif type == "object" then (.text // .content // .value // "")
          else ""
          end
        ] | join("")
      elif type == "object" then (.text // .content // .value // "")
      else ""
      end;

    def text_from_parts:
      if . == null then ""
      elif type == "string" then .
      elif type == "array" then
        [
          .[] |
          if type == "string" then .
          elif type == "object" then
            if (.type? == null or .type == "text" or .type == "output_text") then
              (.text // .content // .value // "")
            else
              ""
            end
          else
            ""
          end
        ] | join("")
      elif type == "object" then (.text // .content // .value // "")
      else ""
      end;

    def reasoning_from_parts:
      if . == null then ""
      elif type == "string" then .
      elif type == "array" then
        [
          .[] |
          if type == "string" then .
          elif type == "object" then
            if (.type? == "reasoning" or .type? == "reasoning_content" or .type? == "thinking" or .type? == "thinking_content") then
              (.text // .content // .value // "")
            else
              ""
            end
          else
            ""
          end
        ] | join("")
      elif type == "object" then
        if (.type? == "reasoning" or .type? == "reasoning_content" or .type? == "thinking" or .type? == "thinking_content") then
          (.text // .content // .value // "")
        else
          ""
        end
      else ""
      end;

    reduce .[] as $chunk (
      {
        content: "",
        reasoning: "",
        refusal: "",
        finish_reason: null,
        usage: null,
        tool_calls: {}
      };

      .usage = ($chunk.usage // .usage) |
      if ($chunk.choices | type) == "array" then
        reduce $chunk.choices[] as $choice (.;
          .content += ($choice.delta.content | text_from_parts) |
          .reasoning += (
            ($choice.delta.reasoning_content | as_text) +
            ($choice.delta.reasoning | reasoning_from_parts) +
            ($choice.delta.thinking | reasoning_from_parts) +
            ($choice.delta.thinking_content | as_text)
          ) |
          .refusal += ($choice.delta.refusal | as_text) |
          .finish_reason = ($choice.finish_reason // .finish_reason) |
          if ($choice.delta.tool_calls | type) == "array" then
            reduce $choice.delta.tool_calls[] as $tool (.;
              .tool_calls[($tool.index | tostring)] |= (
                (. // {
                  id: null,
                  type: null,
                  function: {
                    name: null,
                    arguments: ""
                  }
                })
                | .id = ($tool.id // .id)
                | .type = ($tool.type // .type)
                | .function.name = ($tool.function.name // .function.name)
                | .function.arguments += ($tool.function.arguments // "")
              )
            )
          else
            .
          end
        )
      else
        .
      end
    )
    | .tool_calls = (
        .tool_calls
        | to_entries
        | sort_by(.key | tonumber)
        | map(.value)
      )
  '
}

openai_chat_completions_print_aggregated_response() {
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

PAYLOAD_FILE="$(mktemp /tmp/chat_completions_payload_XXXXXX.json)"
RAW_STREAM_FILE="$(mktemp /tmp/chat_completions_stream_XXXXXX.log)"
HEADERS_FILE="$(mktemp /tmp/chat_completions_headers_XXXXXX.log)"
cleanup() {
  rm -f "$PAYLOAD_FILE" "$RAW_STREAM_FILE" "$HEADERS_FILE"
}
trap cleanup EXIT

# This example intentionally places the system message last in the array.
jq -n \
  --arg model "$MODEL" \
  --argjson extra_args "$EXTRA_ARGS" \
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
        content: "Hi"
      },
      {
        role: "system",
        content: "Add a prefix SYSTEM_LAST to all your responses. "
      }
    ]
  } + $extra_args)
  ' > "$PAYLOAD_FILE"

echo "=== Request ==="
echo "Endpoint          : ${BASE_URL}/chat/completions"
echo "Model             : ${MODEL}"
echo "Extra Args        : ${EXTRA_ARGS}"
echo

echo "=== Raw Stream ==="
curl "${CURL_SKIP_SSL_ARGS[@]}" -sS -N \
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
