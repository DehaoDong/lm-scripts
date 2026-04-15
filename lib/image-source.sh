#!/usr/bin/env bash

require_image_bin() {
  local bin="$1"
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "[error] Missing dependency: $bin" >&2
    return 1
  fi
}

prepare_image_data_url() {
  local image_ref="${1:?image reference is required}"
  local mime=""
  local tmp_img=""

  require_image_bin curl
  require_image_bin file
  require_image_bin base64

  if [[ -f "$image_ref" ]]; then
    mime="$(file -b --mime-type "$image_ref")"
    IMAGE_DATA_URL="data:${mime};base64,$(base64 -w0 "$image_ref")"
    IMAGE_SOURCE_SUMMARY="(base64 local file)"
    echo "[info] Encoded local file as data URI (${mime})"
    return 0
  fi

  if [[ "$image_ref" =~ ^https?:// ]]; then
    echo "[info] Downloading remote image for base64 encoding..."
    tmp_img="$(mktemp /tmp/llm_img_XXXXXX)"
    if ! curl -fsSL "$image_ref" -o "$tmp_img"; then
      rm -f "$tmp_img"
      echo "[error] Failed to download remote image: $image_ref" >&2
      return 1
    fi

    mime="$(file -b --mime-type "$tmp_img")"
    IMAGE_DATA_URL="data:${mime};base64,$(base64 -w0 "$tmp_img")"
    IMAGE_SOURCE_SUMMARY="${image_ref} (downloaded & base64)"
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
