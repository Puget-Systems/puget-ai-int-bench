#!/bin/bash
# Wait for the currently running Gemma 4 benchmark to finish
while pgrep -f "run_benchmarks.sh.*team_llm.*8" > /dev/null; do
    sleep 10
done

echo "Starting personal_llm 1"
./run_benchmarks.sh --host ubuntu@172.19.79.127 --cache-proxy http://172.19.168.179:3128 --pack personal_llm --model 1 2>&1 | tee results/run_personal_1_$(date +%Y%m%d_%H%M).log

echo "Starting personal_llm 2"
./run_benchmarks.sh --host ubuntu@172.19.79.127 --cache-proxy http://172.19.168.179:3128 --pack personal_llm --model 2 2>&1 | tee results/run_personal_2_$(date +%Y%m%d_%H%M).log

echo "Starting personal_llm 4"
./run_benchmarks.sh --host ubuntu@172.19.79.127 --cache-proxy http://172.19.168.179:3128 --pack personal_llm --model 4 2>&1 | tee results/run_personal_4_$(date +%Y%m%d_%H%M).log

echo "Starting personal_llm 6"
./run_benchmarks.sh --host ubuntu@172.19.79.127 --cache-proxy http://172.19.168.179:3128 --pack personal_llm --model 6 2>&1 | tee results/run_personal_6_$(date +%Y%m%d_%H%M).log

echo "Starting comfy_ui 1"
./run_benchmarks.sh --host ubuntu@172.19.79.127 --cache-proxy http://172.19.168.179:3128 --pack comfy_ui --model 1 2>&1 | tee results/run_comfy_1_$(date +%Y%m%d_%H%M).log

echo "Starting comfy_ui 2"
./run_benchmarks.sh --host ubuntu@172.19.79.127 --cache-proxy http://172.19.168.179:3128 --pack comfy_ui --model 2 2>&1 | tee results/run_comfy_2_$(date +%Y%m%d_%H%M).log
