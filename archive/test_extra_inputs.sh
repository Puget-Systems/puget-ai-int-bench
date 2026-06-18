#!/bin/bash
docker run --rm --net host nvcr.io/nvidia/tritonserver:25.04-py3-sdk genai-perf profile \
  -m qwen3.6:35b \
  --endpoint-type chat \
  -u http://localhost:11434 \
  --num-prompts 1 \
  --extra-inputs '{"stream_options": {"include_usage": true}}'
