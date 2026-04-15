#!/usr/bin/env bash

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
      elif type == "string" then ""
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
        id: null,
        object: null,
        created: null,
        model: null,
        service_tier: null,
        system_fingerprint: null,
        role: null,
        content: "",
        reasoning: "",
        refusal: "",
        finish_reason: null,
        usage: null,
        tool_calls: {}
      };

      .id = (.id // $chunk.id) |
      .object = (.object // $chunk.object) |
      .created = (.created // $chunk.created) |
      .model = (.model // $chunk.model) |
      .service_tier = (.service_tier // $chunk.service_tier) |
      .system_fingerprint = (.system_fingerprint // $chunk.system_fingerprint) |
      .usage = ($chunk.usage // .usage) |

      if ($chunk.choices | type) == "array" then
        reduce $chunk.choices[] as $choice (.;
          .role = ($choice.delta.role // .role) |
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
        "<thinking>\n" + $reasoning + "\n</thinking>\n\n" + $content
      else
        $content
      end
  '
}

openai_chat_completions_print_metadata() {
  local summary_json="${1:?summary json is required}"

  printf '%s\n' "$summary_json" | jq '{
    id,
    object,
    created,
    model,
    role,
    finish_reason,
    service_tier,
    system_fingerprint
  }'
}

openai_chat_completions_print_usage() {
  local summary_json="${1:?summary json is required}"

  printf '%s\n' "$summary_json" | jq '.usage'
}

openai_chat_completions_print_tool_calls() {
  local summary_json="${1:?summary json is required}"

  printf '%s\n' "$summary_json" | jq '.tool_calls'
}
