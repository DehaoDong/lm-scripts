# lm-scripts

Small Bash examples for streaming LLM APIs and turning raw SSE output into a readable summary.

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
- metadata and usage
- tool/function call details when present

## Repo Layout

```text
.
├── anthropic/
│   ├── hello.sh
│   ├── list-models.sh
│   ├── mm.sh
│   └── mm-tool.sh
├── lib/
│   ├── anthropic-messages-sse.sh
│   ├── image-source.sh
│   ├── openai-chat-completions-sse.sh
│   └── openai-responses-sse.sh
├── openai/
│   ├── list-models.sh
│   ├── chat-completions/
│   │   ├── hello.sh
│   │   ├── mm.sh
│   │   └── mm-tool.sh
│   └── responses/
│       ├── hello.sh
│       ├── mm.sh
│       └── mm-tool.sh
└── resources/
    └── Sydney-Opera-House.jpg
```

## Requirements

- `bash`
- `curl`
- `jq`
- `file` for local/remote image MIME detection in multimodal examples
- `base64` for multimodal examples

## Environment Variables

All scripts expect these variables:

- `BASE_URL`: provider base URL including the version prefix, for example `https://api.openai.com/v1`
- `API_KEY`: provider API key
- `MODEL`: model name to send in generation requests

`MODEL` is not required for the `list-models.sh` scripts.

Examples:

```bash
export BASE_URL=https://api.openai.com/v1 && \
export API_KEY=your_api_key && \
export MODEL=gpt-4.1
```

```bash
export BASE_URL=https://api.anthropic.com/v1
export API_KEY=your_api_key
export MODEL=claude-sonnet-4-0
```

You can also point `BASE_URL` at a compatible local gateway, for example:

```bash
export BASE_URL=http://localhost:10000/v1
export API_KEY=xxx
export MODEL=Qwen3.5-4B
```

## Quick Start

Run commands from the repo root:

```bash
bash openai/chat-completions/hello.sh
```

```bash
bash openai/responses/hello.sh
```

```bash
bash openai/list-models.sh
```

```bash
bash anthropic/hello.sh
```

```bash
bash anthropic/list-models.sh
```

## Scripts

### OpenAI

- `openai/list-models.sh`
  Lists models from `${BASE_URL}/models` using OpenAI bearer auth.

### OpenAI Chat Completions

- `openai/chat-completions/hello.sh`
  Text-only streaming request to `${BASE_URL}/chat/completions`.
- `openai/chat-completions/mm.sh`
  Simulates an image-reading workflow where the image is sent in a later `user` message.
- `openai/chat-completions/mm-tool.sh`
  Simulates the same workflow, but returns the image in a `tool` message.

### OpenAI Responses

- `openai/responses/hello.sh`
  Text-only streaming request to `${BASE_URL}/responses`.
- `openai/responses/mm.sh`
  Sends multimodal user input with `input_text` and `input_image`.
- `openai/responses/mm-tool.sh`
  Simulates a `function_call` followed by `function_call_output` containing text plus an image.

### Anthropic Messages

- `anthropic/list-models.sh`
  Lists models from `${BASE_URL}/models` using Anthropic auth/version headers.
- `anthropic/hello.sh`
  Text-only streaming request to `${BASE_URL}/messages`.
- `anthropic/mm.sh`
  Sends a user message with text plus a base64-encoded image block.
- `anthropic/mm-tool.sh`
  Simulates a `tool_use` followed by a `tool_result` containing text plus an image.

## Multimodal Notes

- Multimodal examples set `IMAGE` inside each script.
- `IMAGE` can be a local file path or an `http(s)` URL.
- Remote images are downloaded and converted to base64 by [`lib/image-source.sh`](lib/image-source.sh).
- Some examples use the bundled [`resources/Sydney-Opera-House.jpg`](resources/Sydney-Opera-House.jpg), so running from the repo root is the safest default.

If you want to swap the sample image, edit the `IMAGE=...` line in the relevant script.

## Output Shape

Most scripts print sections in this order:

1. `=== Request ===`
2. `=== Raw Stream ===`
3. `=== Aggregated LLM Response ===`
4. `=== Metadata ===`
5. `=== Usage ===`
6. `=== Tool Calls ===`, `=== Function Calls ===`, or `=== Tool Uses ===`

The parsing helpers in [`lib/openai-chat-completions-sse.sh`](lib/openai-chat-completions-sse.sh), [`lib/openai-responses-sse.sh`](lib/openai-responses-sse.sh), and [`lib/anthropic-messages-sse.sh`](lib/anthropic-messages-sse.sh) collapse raw SSE events into a single summary JSON object before printing the readable sections.

The `list-models.sh` scripts are non-streaming and print `=== Raw Response ===`, `=== Models ===`, and `=== Metadata ===` instead.
