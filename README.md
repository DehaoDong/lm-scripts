# lm-scripts

Small standalone Bash examples for streaming LLM APIs and turning raw SSE output into a readable summary.

The repo currently covers:

- OpenAI `chat/completions`
- OpenAI `responses`
- Anthropic `messages`
- Text-only and multimodal request patterns
- Tool-call style flows where an image is returned from a simulated tool result

Each example prints:

- the request target
- the raw streamed SSE events
- an aggregated final response

Each script is self-contained and can be copied or run independently.

## Repo Layout

```text
.
├── hello/
│   ├── anthropic.sh
│   ├── openai-chat.sh
│   └── openai-responses.sh
├── list-models/
│   ├── anthropic.sh
│   └── openai.sh
├── multimodal/
│   ├── anthropic.sh
│   ├── openai-chat.sh
│   └── openai-responses.sh
├── multimodal-tool/
│   ├── anthropic.sh
│   ├── openai-chat.sh
│   └── openai-responses.sh
└── system-last/
    ├── openai-chat.sh
    └── openai-responses.sh
```

## Requirements

- `bash`
- `curl`
- `jq`
- `file` for local/remote image MIME detection in multimodal examples
- `base64` for multimodal examples

## Arguments

Scripts take all inputs as explicit command-line arguments.

Text generation scripts:

```text
bash <script>.sh -u <url> -k <key> -m <model> [-e <json>] [-s|--skip-ssl]
```

Multimodal scripts:

```text
bash <script>.sh -u <url> -k <key> -m <model> -i <image> [-e <json>] [-s|--skip-ssl]
```

List-models scripts:

```text
bash <script>.sh -u <url> -k <key> [-s|--skip-ssl]
```

All scripts print usage help when run with no arguments or with `-h` / `--help`.

Arguments:

- `-u, --url`: provider base URL including the version prefix, for example `https://api.openai.com/v1`
- `-k, --key`: provider API key
- `-m, --model`: model name to send in generation requests
- `-i, --image`: local file path or `http(s)` URL for multimodal scripts
- `-e, --extra-args`: optional JSON object string merged into the request body and passed through to the API. It defaults to `{}`.
- `-s, --skip-ssl`: optional flag that skips TLS certificate verification for API requests and remote image downloads.

You can point `--url` at a compatible local gateway, for example `http://localhost:10000/v1`.

There is intentionally no default image for multimodal scripts.

## Quick Start

Run commands from the repo root:

```bash
bash hello/openai-chat.sh -u https://api.openai.com/v1 -k your_api_key -m gpt-4.1
```

```bash
bash hello/openai-responses.sh -u https://api.openai.com/v1 -k your_api_key -m gpt-4.1
```

```bash
bash list-models/openai.sh -u https://api.openai.com/v1 -k your_api_key
```

```bash
bash hello/anthropic.sh -u https://api.anthropic.com/v1 -k your_api_key -m claude-sonnet-4-0
```

```bash
bash list-models/anthropic.sh -u https://api.anthropic.com/v1 -k your_api_key
```

## Scripts

- `list-models/openai.sh`
  Lists models from `<url>/models` using OpenAI bearer auth.
- `list-models/anthropic.sh`
  Lists models from `<url>/models` using Anthropic auth/version headers.
- `hello/openai-chat.sh`
  Text-only streaming request to `<url>/chat/completions`.
- `hello/openai-responses.sh`
  Text-only streaming request to `<url>/responses`.
- `hello/anthropic.sh`
  Text-only streaming request to `<url>/messages`.
- `multimodal/openai-chat.sh`
  Sends multimodal user input with OpenAI Chat `image_url` content.
- `multimodal/openai-responses.sh`
  Sends multimodal user input with `input_text` and `input_image`.
- `multimodal/anthropic.sh`
  Sends a user message with text plus a base64-encoded image block.
- `multimodal-tool/openai-chat.sh`
  Simulates `assistant.tool_calls` followed by a `tool` message containing text plus an image.
- `multimodal-tool/openai-responses.sh`
  Simulates a `function_call` followed by `function_call_output` containing text plus an image.
- `multimodal-tool/anthropic.sh`
  Simulates an assistant `tool_use` followed by a matching user `tool_result` containing text plus an image.
- `system-last/openai-chat.sh`
  Text-only streaming request that intentionally places the `system` message last in Chat Completions `messages`.
- `system-last/openai-responses.sh`
  Text-only streaming request that intentionally places the `system` message last in Responses API `input`.

## Multimodal Notes

- Multimodal scripts require the `<image>` argument.
- `<image>` can be a local file path or an `http(s)` URL.
- Remote images are downloaded and converted to base64 by code inside each multimodal script.
- Quote remote image URLs that contain shell metacharacters such as `&`, `?`, or `#`.
  Otherwise the shell may run the script in the background before the full URL is passed.
- There is no default image.

## Output Shape

Most scripts print sections in this order:

1. `=== Request ===`
2. `=== Raw Stream ===`
3. `=== Aggregated LLM Response ===`

Each streaming script contains its own SSE parsing code and image handling code.

The `list-models` scripts are non-streaming and print `=== Raw Response ===`, pretty-printed model JSON under `=== Models ===`, and `Model Count`.
