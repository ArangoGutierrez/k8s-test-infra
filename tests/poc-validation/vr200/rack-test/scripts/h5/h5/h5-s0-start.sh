#!/bin/bash
# H5 step 0: verify the start state the brief requires. Exits non-zero if any
# of it does not hold: 64/64 Ready (10 real, 54 KWOK), 3 SGPURacks, 3 distinct
# clique values x 18 KWOK nodes, no clique on a real node, 336 gpu.nvidia.com
# devices (Hopper 168 / Blackwell 84 / Rubin 84), KWOK stages without
# pod-complete, no ResourceClaim anywhere, no host /dev/nvidia* in kind nodes.
set -uo pipefail
mkdir -p "${HOME}/mokka-hetero/logs"
LOG="${HOME}/mokka-hetero/logs/h5-s0-start.log"
exec > >(tee "${LOG}") 2>&1
fail=0
chk() { if [[ "$2" == "$3" ]]; then echo "PASS $1 = $2"; else echo "FAIL $1 got=[$2] want=[$3]"; fail=1; fi; }
echo "start $(date -u +%FT%TZ) context=$(kubectl config current-context)"

r="$(kubectl get --raw /readyz)"; echo "readyz: ${r} rc=$?"
chk readyz "${r}" ok

nodes="$(kubectl get nodes -o json)"
chk "nodes total" "$(jq '.items|length' <<<"${nodes}")" 64
chk "nodes Ready" "$(jq '[.items[] | select(any(.status.conditions[]; .type=="Ready" and .status=="True"))] | length' <<<"${nodes}")" 64
chk "real nodes (no type label)" "$(jq '[.items[] | select(.metadata.labels.type == null)] | length' <<<"${nodes}")" 10
chk "kwok nodes (type=kwok)" "$(jq '[.items[] | select(.metadata.labels.type == "kwok")] | length' <<<"${nodes}")" 54
echo "== real nodes: name profile clique"
jq -r '.items[] | select(.metadata.labels.type == null) | "\(.metadata.name) profile=\(.metadata.labels["nvml-mock/profile"] // "-") clique=\(.metadata.labels["nvidia.com/gpu.clique"] // "-")"' <<<"${nodes}"
chk "real nodes with a clique label" "$(jq '[.items[] | select(.metadata.labels.type == null and .metadata.labels["nvidia.com/gpu.clique"] != null)] | length' <<<"${nodes}")" 0
echo "== kwok nodes: count gpu-type clique"
jq -r '.items[] | select(.metadata.labels.type == "kwok") | "\(.metadata.labels["mokka-hetero.nvidia.com/gpu-type"]) \(.metadata.labels["nvidia.com/gpu.clique"] // "-")"' <<<"${nodes}" | sort | uniq -c
chk "distinct (gpu-type, clique) pairs on kwok nodes, each x18" \
  "$(jq -r '.items[] | select(.metadata.labels.type == "kwok") | "\(.metadata.labels["mokka-hetero.nvidia.com/gpu-type"]) \(.metadata.labels["nvidia.com/gpu.clique"] // "-")"' <<<"${nodes}" | sort | uniq -c | awk '$1==18' | wc -l)" 3
chk "distinct clique values" "$(jq -r '[.items[] | .metadata.labels["nvidia.com/gpu.clique"] // empty] | unique | length' <<<"${nodes}")" 3
chk "sgpuracks" "$(kubectl get sgpuracks --no-headers | wc -l)" 3
kubectl get sgpuracks

slices="$(kubectl get resourceslices -o json)"
chk "gpu.nvidia.com devices" "$(jq '[.items[] | select(.spec.driver=="gpu.nvidia.com") | .spec.devices[]] | length' <<<"${slices}")" 336
echo "== devices by architecture"
jq -r '.items[] | select(.spec.driver=="gpu.nvidia.com") | .spec.devices[] | .attributes.architecture.string' <<<"${slices}" | sort | uniq -c
chk "arch counts" "$(jq -r '[.items[] | select(.spec.driver=="gpu.nvidia.com") | .spec.devices[] | .attributes.architecture.string] | group_by(.) | map("\(.[0])=\(length)") | join(" ")' <<<"${slices}")" "Blackwell=84 Hopper=168 Rubin=84"

echo "== kwok stages"
st="$(kubectl get stages.kwok.x-k8s.io -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}')"
echo "${st}"
chk "kwok stages" "${st}" "node-heartbeat-with-lease node-initialize pod-delete pod-ready "
kubectl -n kube-system get pods -l app=kwok-controller -o wide 2>/dev/null || kubectl -n kube-system get pods -o wide | grep kwok

echo "== resourceclaims and templates, all namespaces"
kubectl get resourceclaims,resourceclaimtemplates -A
chk "resourceclaims anywhere" "$(kubectl get resourceclaims -A --no-headers 2>/dev/null | wc -l)" 0
echo "sched-test ns: $(kubectl get ns sched-test --no-headers 2>&1)"

echo "== kind node containers: restarts, start time, host /dev/nvidia* entries"
for n in $(kind get nodes --name mokka-hetero | sort); do
  s="$(docker inspect "${n}" --format '{{.RestartCount}} {{.State.StartedAt}}')"
  d="$(docker exec "${n}" sh -c 'ls -d /dev/nvidia* 2>/dev/null | wc -l')"
  echo "${n} restarts/started=${s} dev-nvidia=${d}"
  [[ "${d}" == "0" ]] || { echo "FAIL ${n} has host /dev/nvidia*"; fail=1; }
done

echo "== pods not Running/Completed"
kubectl get pods -A --no-headers | awk '$4!="Running" && $4!="Completed"'
echo "== busybox on real nodes (crictl images)"
for n in $(kind get nodes --name mokka-hetero | sort); do
  echo "${n}: $(docker exec "${n}" crictl images 2>/dev/null | grep -E 'busybox|pause' | awk '{print $1":"$2}' | tr '\n' ' ')"
done
free -m | sed -n 1,2p
echo "DONE fail=${fail} $(date -u +%FT%TZ)"
exit "${fail}"
