#!/bin/bash
# H3 step 3a: apply H2's SGPURackProfiles and SGPUInventory, wait for the
# Mokka control plane to materialize 3 SGPURacks and project onto the 54 KWOK
# nodes, then dump the live objects for step 3b's checks.
set -uo pipefail
H2="${HOME}/mokka-hetero/h2"
OUT="${HOME}/mokka-hetero/out/h3"
LOG="${HOME}/mokka-hetero/logs/h3-s3a-racks-apply.log"
mkdir -p "${OUT}"
exec > >(tee "${LOG}") 2>&1
echo "start $(date -u +%FT%TZ)"

for f in sgpu-rack-profiles.yaml sgpu-inventory.yaml; do
  kubectl apply --dry-run=server -f "${H2}/racks/${f}"
  rc=$?; echo "dry-run ${f} rc=${rc}"; [[ ${rc} -eq 0 ]] || exit 1
done
kubectl apply -f "${H2}/racks/sgpu-rack-profiles.yaml"; rc=$?; echo "apply profiles rc=${rc}"; [[ ${rc} -eq 0 ]] || exit 1
kubectl apply -f "${H2}/racks/sgpu-inventory.yaml"; rc=$?; echo "apply inventory rc=${rc}"; [[ ${rc} -eq 0 ]] || exit 1
t0="$(date +%s)"

ok=0
for i in $(seq 1 60); do
  racks="$(kubectl get sgpuracks.mokka.nvidia.com --no-headers 2>/dev/null | wc -l)"
  assigned="$(kubectl get nodes -l 'mokka.nvidia.com/sgpu-assigned=true,nvidia.com/gpu.clique' --no-headers 2>/dev/null | wc -l)"
  echo "t+$(( $(date +%s) - t0 ))s racks=${racks} assigned+clique nodes=${assigned}"
  if [[ "${racks}" == "3" && "${assigned}" == "54" ]]; then ok=1; break; fi
  sleep 5
done

kubectl get sgpurackprofiles,sgpuinventories,sgpuracks -o wide
kubectl get sgpuinventories.mokka.nvidia.com mokka-hetero -o json >"${OUT}/sgpuinventory.json"
kubectl get sgpuracks.mokka.nvidia.com -o json >"${OUT}/sgpuracks.json"
kubectl get nodes -o json >"${OUT}/nodes-after-racks.json"
echo "== inventory status"
jq '.status' "${OUT}/sgpuinventory.json"
echo "== control-plane log (tail)"
kubectl -n mokka logs deploy/nvml-mock-h100-control-plane --since=10m 2>&1 | tail -25 | cut -c1-400
echo "DONE ok=${ok} $(date -u +%FT%TZ)"
[[ ${ok} -eq 1 ]]
