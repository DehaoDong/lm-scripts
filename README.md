# lm-scripts

## Usage

```bash
BASE_URL=http://localhost:10000/v1 \
API_KEY=xxx \
MODEL=Qwen3.5-4B \
bash openai-stream.sh 
```

## Description

- `openai-stream.sh` OpenAI chat completions api, raw stream events
- `openai-mm.sh` OpenAI chat completions api, multimodal in user message
- `openai-mm-tool.sh` OpenAI chat completions api, multimodal in tool message
- `openai-responses-mm.sh` OpenAI responses api, multimodal in user message
- `openai-responses-mm-tool.sh` OpenAI responses api, multimodal in function_call_output
- `anthropic-mm.sh` Anthropic api, multimodal in user message
- `anthropic-mm-tool.sh` Anthropic api, multimodal in tool result
