#!/bin/bash
# Step 3: create the kind cluster from the DRA-guide config.
set -uo pipefail
cd ~/mokka-hetero
echo "start $(date -u +%FT%TZ)"
kind create cluster --config scripts/kind-mokka-hetero.yaml --wait 5m
rc=$?
echo "kind create rc=${rc} $(date -u +%FT%TZ)"
kubectl --context kind-mokka-hetero get nodes -L nvml-mock/profile -L nvidia.com/gpu.present -o wide
echo "DONE rc=${rc}"
