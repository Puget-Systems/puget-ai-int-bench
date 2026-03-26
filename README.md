# Puget Systems AI Internal Benchmarks

This repository contains automated benchmarking scripts for the Puget Systems Docker App Packs (Personal LLM, Team LLM, and ComfyUI).

## Structure
* `llm_tests/`: Contains `genai-perf` scripts and practical "Day in the Life" LLM tests for Ollama and vLLM.
* `comfyui_tests/`: Contains Python scripts interacting with the ComfyUI API to queue standard image/video generation workflows.
* `results/`: Output directory for generated CSV/JSON reports containing system specs and performance metrics.

## Usage
Run the main orchestration script:
```bash
./run_benchmarks.sh
```