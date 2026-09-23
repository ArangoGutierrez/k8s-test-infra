#!/bin/bash
# Step 5: Mokka CRDs, three nvml-mock releases (fleet pattern), control plane on
# exactly one (nvml-mock-h100).
set -uo pipefail
cd ~/mokka-hetero/src
CTX=kind-mokka-hetero
CHART=deployments/nvml-mock/helm/nvml-mock
echo "start $(date -u +%FT%TZ)"
helm upgrade --install mokka-crds deployments/mokka-crds/helm/mokka-crds --kube-context "${CTX}"
echo "mokka-crds rc=$?"
kubectl --context "${CTX}" get crd | grep mokka
common=(--kube-context "${CTX}" --namespace mokka --create-namespace
  --set image.repository=nvml-mock --set image.tag=hetero --set image.pullPolicy=Never
  --wait --timeout 300s)
for p in h100 gb300 vr200; do
  extra=()
  if [ "${p}" = h100 ]; then
    extra=(--set controlPlane.enabled=true
      --set controlPlane.image.repository=mokka-control-plane
      --set controlPlane.image.tag=hetero
      --set controlPlane.image.allowMutableTag=true
      --set controlPlane.image.pullPolicy=Never)
  fi
  helm install "nvml-mock-${p}" "${CHART}" "${common[@]}" \
    --set gpu.profile="${p}" --set "nodeSelector.nvml-mock/profile=${p}" "${extra[@]}"
  echo "helm install nvml-mock-${p} rc=$? $(date -u +%FT%TZ)"
done
helm --kube-context "${CTX}" list -A
kubectl --context "${CTX}" -n mokka get ds,deploy,pods -o wide
echo DONE
