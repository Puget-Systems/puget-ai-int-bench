#!/bin/bash
# Qwen3 8B Thinking Model — Extended Timeout Benchmark
# Re-runs Qwen3 8B with measurement interval extended to properly
# capture reasoning/thinking model behavior.
#
# The standard 30s measurement window causes concurrency=1 to show 0.0 tok/s
# because Qwen3's thinking phase generates hundreds of internal tokens before
# any visible output arrives. This script uses 120s measurement to let the
# thinking phase complete within the measurement window.

set -euo pipefail

HOST="labs@172.19.28.207"
REPO="/Users/dustmoo/Sites/puget-docker-app-pack"

echo "==========================================================="
echo "Qwen3 8B Thinking Model — Extended Timeout Benchmark"
echo "Target Host: $HOST"
echo "==========================================================="
echo ""
echo "Key differences from standard run:"
echo "  • measurement-interval: 120000ms (2 min, was 30000ms)"
echo "  • num-prompts:          20       (was 50, each takes longer)"
echo "  • output-tokens:        500      (standard)"
echo "  • concurrency:          1,4,8    (standard)"
echo ""

# Qwen3 8B Dense FP16 (TP=1, single GPU) — model choice 10
echo "=== Qwen3 8B Dense (TP=1) — Extended Measurement Window ==="
./run_benchmarks.sh \
    --host "$HOST" \
    --repo "$REPO" \
    --pack team_llm \
    --model 10 \
    --concurrency "1,4,8" \
    --input-tokens 500 \
    --output-tokens 500 \
    --num-prompts 20 \
    --measurement-interval 120000 \
    --skip-checksum
echo ""

echo "==========================================================="
echo "Qwen3 Thinking Benchmark Complete!"
echo "==========================================================="
