#!/bin/sh
# Runs inside the unmodified lmsysorg/sglang image on a Mokka vr200 node.
set -u
echo "== nvidia-smi inside the SGLang pod"
nvidia-smi -L
nvidia-smi --query-gpu=name,memory.total,compute_cap,driver_version --format=csv
echo "== SGLang's own view of the hardware"
python3 /probes/sglang_discovery.py
echo "== sglang.launch_server: how far it gets"
timeout 240 python3 -m sglang.launch_server --model-path Qwen/Qwen2.5-0.5B-Instruct \
  --host 0.0.0.0 --port 30000 --disable-cuda-graph > /tmp/launch.log 2>&1
echo "RESULT launch_rc=$?"
echo "RESULT launch_stop=$(grep -m1 -oE 'RuntimeError: .*' /tmp/launch.log)"
echo "RESULT launch_listening=$(grep -cE 'Uvicorn running|Application startup complete' /tmp/launch.log)"
exit 0
