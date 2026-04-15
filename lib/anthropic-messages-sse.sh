#!/usr/bin/env bash

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
        id: null,
        type: null,
        role: null,
        model: null,
        stop_reason: null,
        stop_sequence: null,
        usage: null,
        text: "",
        thinking: "",
        tool_uses: {},
        error: null
      };

      if $event.type == "message_start" then
        .id = ($event.message.id // .id) |
        .type = ($event.message.type // .type) |
        .role = ($event.message.role // .role) |
        .model = ($event.message.model // .model) |
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
        .stop_reason = ($event.delta.stop_reason // .stop_reason) |
        .stop_sequence = ($event.delta.stop_sequence // .stop_sequence) |
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
        "<thinking>\n" + $thinking + "\n</thinking>\n\n" + $text
      else
        $text
      end
  '
}

anthropic_messages_print_metadata() {
  local summary_json="${1:?summary json is required}"

  printf '%s\n' "$summary_json" | jq '{
    id,
    type,
    role,
    model,
    stop_reason,
    stop_sequence
  }'
}

anthropic_messages_print_usage() {
  local summary_json="${1:?summary json is required}"

  printf '%s\n' "$summary_json" | jq '.usage'
}

anthropic_messages_print_tool_uses() {
  local summary_json="${1:?summary json is required}"

  printf '%s\n' "$summary_json" | jq '.tool_uses'
}
