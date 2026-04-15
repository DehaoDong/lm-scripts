#!/usr/bin/env bash

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
        id: null,
        object: null,
        created_at: null,
        model: null,
        service_tier: null,
        status: null,
        content: "",
        reasoning: "",
        refusal: "",
        usage: null,
        function_calls: {},
        error: null
      };

      if $event.type == "response.created" then
        .id = $event.response.id |
        .object = $event.response.object |
        .created_at = $event.response.created_at |
        .model = $event.response.model |
        .service_tier = ($event.response.service_tier // .service_tier)

      elif $event.type == "response.output_text.delta" then
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
        .status = $event.response.status |
        .usage = ($event.response.usage // .usage) |
        .model = ($event.response.model // .model) |
        .service_tier = ($event.response.service_tier // .service_tier) |
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
        "<thinking>\n" + $reasoning + "\n</thinking>\n\n" + $content
      else
        $content
      end
  '
}

openai_responses_print_metadata() {
  local summary_json="${1:?summary json is required}"

  printf '%s\n' "$summary_json" | jq '{
    id,
    object,
    created_at,
    model,
    status,
    service_tier
  }'
}

openai_responses_print_usage() {
  local summary_json="${1:?summary json is required}"

  printf '%s\n' "$summary_json" | jq '.usage'
}

openai_responses_print_function_calls() {
  local summary_json="${1:?summary json is required}"

  printf '%s\n' "$summary_json" | jq '.function_calls'
}
