#!/bin/bash
# Step 6: DRA driver 0.5.0 exactly as docs/guides/dra.md Step 3 (the
# nvidia.com/gpu.present=true label is already on the 9 workers via the kind
# config). Only change: --timeout 300s instead of 180s for 9 node image pulls.
set -uo pipefail
CTX=kind-mokka-hetero
echo "start $(date -u +%FT%TZ)"
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia >/dev/null 2>&1; helm repo update nvidia >/dev/null
helm install nvidia-dra-driver nvidia/dra-driver-nvidia-gpu \
  --kube-context "${CTX}" \
  --version 0.5.0 \
  --namespace nvidia --create-namespace \
  --set nvidiaDriverRoot=/var/lib/nvml-mock/driver \
  --set gpuResourcesEnabledOverride=true \
  --set resources.computeDomains.enabled=false \
  --wait --timeout 300s
rc=$?
echo "helm install dra rc=${rc} $(date -u +%FT%TZ)"
kubectl --context "${CTX}" -n nvidia get pods -o wide
kubectl --context "${CTX}" -n nvidia wait --for=condition=ready pod --all --timeout=120s
echo "wait rc=$?"
echo "DONE rc=${rc}"
