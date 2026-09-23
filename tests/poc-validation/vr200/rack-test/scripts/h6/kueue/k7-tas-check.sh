#!/bin/bash
# H6 Kueue step 7: the TAS scenarios, each exiting non-zero on failure.
#   T0 preconditions (rack empty, accounting == slices, queue empty)
#   T1 tas-c19 on the empty rack: never admitted, TAS reason
#   T2 tas-a: admitted, 18 pods on 18 distinct trays of ONE rack, and every
#      pod's DRA allocation is on the node TAS chose
#   T3 tas-b while tas-a runs: held by TOPOLOGY while quota has room
#   T4 delete tas-a: tas-b is admitted (it was held by occupancy, nothing else)
# Run from ~/mokka-hetero/h6/kueue after k1-k3 and `kubectl apply -f k4-tas-objects.yaml`.
set -uo pipefail
LOG="${HOME}/mokka-hetero/logs/h6-k7-tas-check.log"
mkdir -p "$(dirname "${LOG}")"
exec > >(tee "${LOG}") 2>&1
NS=mokka-hetero-kueue
RES=mokka-hetero.nvidia.com/tas-vr200-gpu
echo "start $(date -u +%FT%TZ)"
fail=0
pass() { echo "PASS $*"; }
bad() { echo "FAIL $*"; fail=1; }

wl_json() { # Workload owned by Job $1
  kubectl -n "${NS}" get workloads.kueue.x-k8s.io -o json |
    jq --arg j "$1" '[.items[] | select(any(.metadata.ownerReferences[]?; .kind=="Job" and .name==$j))] | first // {}'
}
cond() { # $1 workload json, $2 condition type -> "status|reason|message"
  jq -r --arg t "$2" '(.status.conditions // [])[] | select(.type==$t) | "\(.status)|\(.reason)|\(.message)"' <<< "$1"
}
wait_wl() { # $1 job, $2 jq predicate on the workload, $3 timeout s
  local t=0 w
  while (( t < $3 )); do
    w="$(wl_json "$1")"
    if jq -e "$2" <<< "${w}" > /dev/null 2>&1; then printf '%s' "${w}"; return 0; fi
    sleep 3; t=$((t + 3))
  done
  printf '%s' "${w}"; return 1
}
cq_used() {
  kubectl get clusterqueues.kueue.x-k8s.io vr200 -o json |
    jq -r --arg r "${RES}" '[.status.flavorsReservation[]? | select(.name=="vr200-rack") | .resources[]? | select(.name==$r) | .total] | first // "0"'
}

echo "== T0 preconditions"
alloc_on_rack="$(kubectl get resourceclaims -A -o json | jq '[.items[] | select(.status.allocation != null)
  | .status.allocation.devices.results[]? | select(.pool | startswith("kwok-vr200-"))] | length')"
[[ "${alloc_on_rack}" == "0" ]] && pass "no allocated device in the VR200 rack" || bad "rack not empty: ${alloc_on_rack} allocated devices (delete S1-S3 / blindspot first)"
drift="$(kubectl get nodes -l mokka-hetero.nvidia.com/gpu-type=vr200 -o json | jq -r --arg r "${RES}" '.items[] | "\(.metadata.name) \(.status.allocatable[$r] // "none")"' |
  while read -r n a; do c="$(kubectl get resourceslices --field-selector spec.nodeName="${n}" -o json | jq '[.items[] | select(.spec.driver=="gpu.nvidia.com") | .spec.devices | length] | add // 0')"; [[ "${a}" == "${c}" ]] || echo "${n} alloc=${a} slice=${c}"; done)"
[[ -z "${drift}" ]] && pass "accounting resource equals slice device count on all 18 VR200 trays" || bad "drift: ${drift}"
[[ "$(cq_used)" == "0" ]] && pass "ClusterQueue vr200 has no reservation" || bad "ClusterQueue vr200 already reserves $(cq_used)"
(( fail == 0 )) || { echo "DONE fail=${fail} (preconditions)"; exit 1; }

echo "== T1 tas-c19 on the empty rack"
kubectl apply -f k5-job-c19.yaml
w="$(wait_wl tas-c19 '(.status.conditions // []) | any(.type=="QuotaReserved" and .status=="False" and (.message|test("topology")))' 90)"
c="$(cond "${w}" QuotaReserved)"; echo "QuotaReserved: ${c}"
[[ "${c}" == False*"allows to fit only 18 out of 19 pod(s)"* ]] && pass "T1 19 trays held by topology" || bad "T1 unexpected: ${c}"
kubectl -n "${NS}" delete job tas-c19 --wait=true

echo "== T2 tas-a"
kubectl apply -f k5-job-a.yaml
w="$(wait_wl tas-a '(.status.conditions // []) | any(.type=="Admitted" and .status=="True")' 120)" || bad "T2 tas-a not admitted: $(cond "${w}" QuotaReserved)"
for _ in $(seq 1 60); do
  running="$(kubectl -n "${NS}" get pods -l mokka-hetero.nvidia.com/kueue-job=tas-a --field-selector=status.phase=Running -o name | wc -l)"
  [[ "${running}" -eq 18 ]] && break; sleep 5
done
kubectl -n "${NS}" get pods -l mokka-hetero.nvidia.com/kueue-job=tas-a -o json > /tmp/h6-tas-a-pods.json
kubectl get nodes -o json > /tmp/h6-nodes.json
jq -r --slurpfile nodes /tmp/h6-nodes.json '
  ($nodes[0].items | map({(.metadata.name): (.metadata.labels["nvidia.com/gpu.clique"] // "NONE")}) | add) as $clq
  | [.items[] | {pod: .metadata.name, node: .spec.nodeName, phase: .status.phase, sel: .spec.nodeSelector["kubernetes.io/hostname"]}] as $p
  | "pods=\($p|length) running=\([$p[]|select(.phase=="Running")]|length) distinct_nodes=\([$p[].node]|unique|length) kwok_vr200_nodes=\([$p[].node|select(startswith("kwok-vr200-"))]|unique|length) cliques=\([$p[].node|$clq[.]]|unique) selector_eq_node=\(all($p[]; .sel==.node))"' /tmp/h6-tas-a-pods.json | tee /tmp/h6-t2.txt
vr200_clique="$(kubectl get sgpuracks -o json | jq -r '.items[] | select(.spec.identity.rackGroup=="vr200") | "\(.spec.identity.fabricUUID).\(.spec.identity.cliqueID)"')"
grep -q "pods=18 running=18 distinct_nodes=18 kwok_vr200_nodes=18 cliques=\[\"${vr200_clique}\"\] selector_eq_node=true" /tmp/h6-t2.txt \
  && pass "T2 18 pods, 18 trays, one rack (${vr200_clique}), TAS hostname == bound node" || bad "T2 placement: $(cat /tmp/h6-t2.txt) want clique ${vr200_clique}"
# DRA agrees with TAS: each pod's claim is allocated 4 devices from its own node's pool
mism="$(kubectl -n "${NS}" get resourceclaims -o json | jq -r --slurpfile pods /tmp/h6-tas-a-pods.json '
  ($pods[0].items | map({(.metadata.uid): .spec.nodeName}) | add) as $n
  | .items[] | select(.status.reservedFor != null) | .status.reservedFor[0].uid as $u | select($n[$u] != null)
  | [.status.allocation.devices.results[]] as $r
  | select(($r|length) != 4 or any($r[]; .pool != $n[$u])) | "\(.metadata.name) node=\($n[$u]) pools=\([$r[].pool]|unique)"')"
nclaims="$(kubectl -n "${NS}" get resourceclaims -o json | jq --slurpfile pods /tmp/h6-tas-a-pods.json '($pods[0].items|map(.metadata.uid)) as $u | [.items[] | select(.status.reservedFor[0].uid as $x | $u | index($x))] | length')"
[[ -z "${mism}" && "${nclaims}" -eq 18 ]] && pass "T2 18 claims, 4 devices each, all from the pod's own node" || bad "T2 DRA vs TAS: claims=${nclaims} ${mism}"

echo "== T3 tas-b while tas-a holds the rack"
used_before="$(cq_used)"; echo "vr200 reservation of ${RES}: ${used_before} of 144"
kubectl apply -f k5-job-b.yaml
w="$(wait_wl tas-b '(.status.conditions // []) | any(.type=="QuotaReserved" and .status=="False" and ((.message // "")|length>0))' 90)"
c="$(cond "${w}" QuotaReserved)"; echo "QuotaReserved: ${c}"
[[ "${used_before}" == "72" ]] && pass "T3 quota has room (72 of 144 reserved)" || bad "T3 reservation ${used_before}, want 72"
# Exact phrase from Kueue v0.19.5 (probe TestH6ProbeSecondJob). With quota at 72
# the same scenario reads "insufficient unused quota ... 72 more needed" instead
# (probe mutant M2), which this match rejects.
[[ "${c}" == False*'topology "mokka-hetero-rack" doesn'"'"'t allow to fit any of 18 pod(s)'* ]] && pass "T3 tas-b held by topology" || bad "T3 tas-b reason is not topology: ${c}"
[[ "$(kubectl -n "${NS}" get pods -l mokka-hetero.nvidia.com/kueue-job=tas-b -o name | wc -l)" -eq 0 ]] && pass "T3 tas-b created no pods" || bad "T3 tas-b has pods"

echo "== T4 release tas-a; tas-b must now be admitted"
kubectl -n "${NS}" delete job tas-a --wait=true
w="$(wait_wl tas-b '(.status.conditions // []) | any(.type=="Admitted" and .status=="True")' 180)" && pass "T4 tas-b admitted once the rack was free" || bad "T4 tas-b still not admitted: $(cond "${w}" QuotaReserved)"
kubectl -n "${NS}" delete job tas-b --wait=true

echo "DONE fail=${fail} $(date -u +%FT%TZ)"
exit "${fail}"
