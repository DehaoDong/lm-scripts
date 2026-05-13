#!/usr/bin/env bash
set -euo pipefail

BASE_URL=""
API_KEY=""
CURL_SKIP_SSL_ARGS=()

print_help() {
  cat <<'EOF'
Usage:
  bash list-models/openai.sh -u <url> -k <key>

Options:
  -u, --url <url>  OpenAI-compatible API base URL, including the version prefix.
                   Example: https://api.openai.com/v1
  -k, --key <key>  API key used as the Bearer token.
  -s, --skip-ssl   Skip TLS certificate verification.
  -h, --help       Show this help.

Examples:
  bash list-models/openai.sh -u https://api.openai.com/v1 -k sk-...
  bash list-models/openai.sh --url http://localhost:10000/v1 --key dummy-key --skip-ssl
EOF
}

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

require_bin curl
require_bin jq
require_arg BASE_URL
require_arg API_KEY

RAW_RESPONSE_FILE="$(mktemp /tmp/openai_models_response_XXXXXX.json)"
HEADERS_FILE="$(mktemp /tmp/openai_models_headers_XXXXXX.log)"
cleanup() {
  rm -f "$RAW_RESPONSE_FILE" "$HEADERS_FILE"
}
trap cleanup EXIT

echo "=== Request ==="
echo "Endpoint          : ${BASE_URL}/models"
echo

echo "=== Raw Response ==="
curl "${CURL_SKIP_SSL_ARGS[@]}" -sS \
  -D "$HEADERS_FILE" \
  -o >(tee "$RAW_RESPONSE_FILE") \
  "${BASE_URL}/models" \
  -H "Authorization: Bearer ${API_KEY}"
echo
echo

HTTP_CODE="$(awk 'toupper($1) ~ /^HTTP/ { code = $2 } END { print code }' "$HEADERS_FILE")"

if [[ ! "$HTTP_CODE" =~ ^2 ]]; then
  echo "[error] HTTP ${HTTP_CODE}" >&2
  exit 1
fi

jq -e '.' "$RAW_RESPONSE_FILE" >/dev/null

echo "=== Models ==="
jq '.data // []' "$RAW_RESPONSE_FILE"
echo "Model Count       : $(jq '.data // [] | length' "$RAW_RESPONSE_FILE")"
