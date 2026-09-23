#!/bin/bash
# H6 ComputeDomain step 4: apply c3-cd-vr200.yaml and prove the upstream
# ComputeDomain loop ran for real on the 3 VR200 workers. Exits non-zero on
# any failed check.
#
# Why "ComputeDomain Ready" alone is NOT evidence: with an empty clique ID the
# daemon starts no IMEX process (cmd/compute-domain-daemon/main.go:244-250)
# and its readiness check is a no-op success ("check succeeded (noop, clique
# ID is empty)", :436-438); the controller then marks the CD Ready once the
# DaemonSet has numNodes ready pods (compute-domain-controller/daemonset.go:385-390).
# So every check below that touches IMEX must go RED in that mode: C2 (CLIQUE_ID),
# C3 (-q READY), C4 (-N -j UP with 3 NO_GPU nodes), C6 (liveness).
set -uo pipefail
LOG="${HOME}/mokka-hetero/logs/h8-c4-cd-check.log"
mkdir -p "$(dirname "${LOG}")"
exec > >(tee "${LOG}") 2>&1
NS=mokka-hetero-cd
DRV=nvidia
WANT_CLIQUE="00000000-0000-0000-0000-000000000001.32766"   # vr200.yaml:77-80 fabric block
read -r CH_MAJOR _ < "${HOME}/mokka-hetero/tmp/h8-imex-majors.txt"
echo "start $(date -u +%FT%TZ) channel major=${CH_MAJOR}"
fail=0
pass() { echo "PASS $*"; }
bad() { echo "FAIL $*"; fail=1; }
imexctl() { kubectl -n "${DRV}" exec "$1" -c compute-domain-daemon -- nvidia-imex-ctl -c /imexd/imexd.cfg "${@:2}"; }

cd "$(dirname "$0")" || exit 1   # H8: c3 is resolved next to this script
echo "L4 compute apps before:"; nvidia-smi --query-compute-apps=pid --format=csv
kubectl apply -f c3-cd-vr200.yaml
uid=""
for _ in $(seq 1 30); do uid="$(kubectl -n "${NS}" get computedomain vr200-cd -o jsonpath='{.metadata.uid}' 2>/dev/null)"; [[ -n "${uid}" ]] && break; sleep 2; done
echo "ComputeDomain uid=${uid}"
kubectl -n "${NS}" rollout status deploy/vr200-cd-workload --timeout=600s || bad "workload not Ready"

echo "== C1 placement: 3 workload pods on worker7..9, each with 4 Rubin devices from its own node"
kubectl -n "${NS}" get pods -l app=vr200-cd-workload -o json > /tmp/h8-cd-pods.json
nodes="$(jq -r '[.items[] | select(.status.phase=="Running") | .spec.nodeName] | sort | join(",")' /tmp/h8-cd-pods.json)"
[[ "${nodes}" == "mokka-hetero-worker7,mokka-hetero-worker8,mokka-hetero-worker9" ]] && pass "C1 pods on ${nodes}" || bad "C1 pods on '${nodes}'"
gpu_ok="$(kubectl -n "${NS}" get resourceclaims -o json | jq --slurpfile p /tmp/h8-cd-pods.json '
  ($p[0].items | map({(.metadata.uid): .spec.nodeName}) | add) as $n
  | [.items[] | select(.status.allocation != null) | .status.reservedFor[0].uid as $u
     | [.status.allocation.devices.results[] | select(.driver=="gpu.nvidia.com")] as $g
     | select(($g|length)==4 and all($g[]; .pool==$n[$u]))] | length')"
[[ "${gpu_ok}" -eq 3 ]] && pass "C1 3 claims with 4 GPUs from the pod's node" || bad "C1 GPU claims ok=${gpu_ok}"

echo "== C2 daemon pods: one per VR200 worker, Ready, CLIQUE_ID from mock NVML fabric info"
for _ in $(seq 1 60); do
  ready="$(kubectl -n "${DRV}" get pods -l "resource.nvidia.com/computeDomain=${uid}" -o json | jq '[.items[] | select(any(.status.conditions[]?; .type=="Ready" and .status=="True"))] | length')"
  [[ "${ready}" -eq 3 ]] && break; sleep 5
done
mapfile -t daemons < <(kubectl -n "${DRV}" get pods -l "resource.nvidia.com/computeDomain=${uid}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
[[ "${#daemons[@]}" -eq 3 && "${ready}" -eq 3 ]] && pass "C2 3 daemon pods Ready" || bad "C2 daemons=${#daemons[@]} ready=${ready}"
for d in "${daemons[@]}"; do
  cl="$(kubectl -n "${DRV}" exec "${d}" -c compute-domain-daemon -- /busybox/sh -c 'tr "\0" "\n" < /proc/1/environ | grep ^CLIQUE_ID=' 2>&1)"
  [[ "${cl}" == "CLIQUE_ID=${WANT_CLIQUE}" ]] && pass "C2 ${d} ${cl}" || bad "C2 ${d} '${cl}' want CLIQUE_ID=${WANT_CLIQUE}"
done

echo "== C3 local IMEX probe, the upstream readiness contract (main.go:445): exactly READY"
for d in "${daemons[@]}"; do
  q="$(imexctl "${d}" -q 2>&1)"
  [[ "${q}" == "READY" ]] && pass "C3 ${d} -q ${q}" || bad "C3 ${d} -q '${q}'"
done

echo "== C4 IMEX domain: UP, 3 nodes READY, version NO_GPU (real nvidia-imex --nogpu via the shim)"
dom=""
for _ in $(seq 1 80); do   # first convergence can take ~4 min (docs/guides/compute-domain/README.md:335-340)
  dom="$(imexctl "${daemons[0]}" -N -j 2>/dev/null)"
  [[ "$(jq -r '.status' <<< "${dom}" 2>/dev/null)" == "UP" ]] && break; sleep 3
done
echo "${dom}" | jq -c '{status, nodes: [.nodes[]? | {status, version}]}'
[[ "$(jq -r '.status' <<< "${dom}")" == "UP" ]] && pass "C4 domain UP" || bad "C4 domain status $(jq -r '.status' <<< "${dom}" 2>/dev/null)"
[[ "$(jq '[.nodes[]? | select(.status=="READY" and .version=="NO_GPU")] | length' <<< "${dom}")" -eq 3 ]] && pass "C4 3 nodes READY NO_GPU" || bad "C4 nodes not 3x READY/NO_GPU"

echo "== C5 API objects: CD Ready; one ComputeDomainClique with 3 Ready daemons; channel in every pod"
[[ "$(kubectl -n "${NS}" get computedomain vr200-cd -o jsonpath='{.status.status}')" == "Ready" ]] && pass "C5 ComputeDomain Ready (necessary, not sufficient)" || bad "C5 CD not Ready"
kubectl -n "${DRV}" get computedomaincliques -o json | jq -r --arg u "${uid}" '.items[] | select(.metadata.name|startswith($u)) | "\(.metadata.name) \([.daemons[]? | "\(.nodeName)=\(.status)"] | sort | join(","))"' | tee /tmp/h8-cdclique.txt
[[ "$(wc -l < /tmp/h8-cdclique.txt)" -eq 1 ]] && grep -q "^${uid}.${WANT_CLIQUE} mokka-hetero-worker7=Ready,mokka-hetero-worker8=Ready,mokka-hetero-worker9=Ready$" /tmp/h8-cdclique.txt \
  && pass "C5 clique ${uid}.${WANT_CLIQUE} holds worker7..9 Ready" || bad "C5 clique objects: $(cat /tmp/h8-cdclique.txt)"
want_major="$(printf '%x' "${CH_MAJOR}")"
for p in $(jq -r '.items[].metadata.name' /tmp/h8-cd-pods.json); do
  st="$(kubectl -n "${NS}" exec "${p}" -- stat -c '%F %t' /dev/nvidia-caps-imex-channels/channel0 2>&1)"
  [[ "${st}" == "character special file ${want_major}" ]] && pass "C5 ${p} channel0 is a char device with mock major ${CH_MAJOR}" || bad "C5 ${p} channel0 '${st}' want major ${want_major} (hex)"
done

echo "== C6 liveness: delete the worker9 daemon pod; worker7's view must leave UP, then return to UP"
d9="$(kubectl -n "${DRV}" get pods -l "resource.nvidia.com/computeDomain=${uid}" --field-selector spec.nodeName=mokka-hetero-worker9 -o name)"
d7="$(kubectl -n "${DRV}" get pods -l "resource.nvidia.com/computeDomain=${uid}" --field-selector spec.nodeName=mokka-hetero-worker7 -o jsonpath='{.items[0].metadata.name}')"
kubectl -n "${DRV}" delete "${d9}" --wait=false
left=""; for _ in $(seq 1 40); do s="$(imexctl "${d7}" -N -j 2>/dev/null | jq -r '.status' 2>/dev/null)"; [[ "${s}" != "UP" ]] && { left="${s}"; break; }; sleep 3; done
[[ -n "${left}" ]] && pass "C6 domain left UP after peer loss (status=${left})" || bad "C6 domain stayed UP with a peer gone"
back=""; for _ in $(seq 1 100); do s="$(imexctl "${d7}" -N -j 2>/dev/null | jq -r '.status' 2>/dev/null)"; [[ "${s}" == "UP" ]] && { back=1; break; }; sleep 3; done
[[ -n "${back}" ]] && pass "C6 domain back UP after the DaemonSet replaced the daemon" || bad "C6 domain did not recover"

echo "L4 compute apps after:"; nvidia-smi --query-compute-apps=pid --format=csv
[[ "$(nvidia-smi --query-compute-apps=pid --format=csv,noheader | wc -l)" -eq 0 ]] && pass "real L4 has no compute apps" || bad "real L4 has compute apps"
echo "DONE fail=${fail} $(date -u +%FT%TZ)"
exit "${fail}"
