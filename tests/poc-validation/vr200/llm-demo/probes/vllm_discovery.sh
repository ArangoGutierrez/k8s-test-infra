#!/bin/sh
# Runs inside the unmodified vllm/vllm-openai image on a Mokka vr200 node.
set -u
echo "== nvidia-smi inside the vLLM pod"
nvidia-smi -L
nvidia-smi --query-gpu=name,memory.total,compute_cap,driver_version --format=csv
echo "== vLLM's own view of the hardware (no CUDA context)"
python3 /probes/vllm_discovery.py
echo "== vllm serve: how far it gets"
timeout 300 vllm serve Qwen/Qwen2.5-0.5B-Instruct --enforce-eager \
  --max-model-len 2048 --port 8000 > /tmp/serve.log 2>&1
echo "RESULT serve_rc=$?"
echo "RESULT serve_config=$(grep -m1 -oE 'max_num_batched_tokens=[0-9]+' /tmp/serve.log)"
echo "RESULT serve_stop=$(grep -m1 -oE 'RuntimeError: .*' /tmp/serve.log)"
echo "RESULT serve_listening=$(grep -cE 'Uvicorn running|Application startup complete' /tmp/serve.log)"
exit 0
