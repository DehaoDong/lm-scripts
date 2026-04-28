#!/usr/bin/env bash

ENABLE_THINKING_RAW="${ENABLE_THINKING:-false}"

normalize_bool_json() {
  local value
  value="$(printf '%s' "${1:-false}" | tr '[:upper:]' '[:lower:]')"

  case "$value" in
    1|true|yes|on)
      printf 'true\n'
      ;;
    0|false|no|off|'')
      printf 'false\n'
      ;;
    *)
      echo "[error] Invalid boolean value: ${1}" >&2
      exit 1
      ;;
  esac
}

ENABLE_THINKING_JSON="$(normalize_bool_json "$ENABLE_THINKING_RAW")"

thinking_status_label() {
  if [[ "$ENABLE_THINKING_JSON" == "true" ]]; then
    printf 'enabled\n'
  else
    printf 'disabled\n'
  fi
}

thinking_overrides_json() {
  printf '{"enable_thinking":%s,"chat_template_kwargs":{"enable_thinking":%s}}\n' \
    "$ENABLE_THINKING_JSON" \
    "$ENABLE_THINKING_JSON"
}
