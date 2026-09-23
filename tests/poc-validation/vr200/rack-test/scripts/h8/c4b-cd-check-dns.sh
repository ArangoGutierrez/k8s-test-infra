#!/bin/bash
# H8 c4b: C4-C6 re-expressed for IMEXDaemonsWithDNSNames=true (the v0.5.0
# default). In that mode each daemon's /imexd/nodes.cfg lists
# MAX_NODES_PER_IMEX_DOMAIN (18) DNS slots compute-domain-daemon-0000..0017,
# so a 3-node domain reports DEGRADED (3 READY + 15 UNAVAILABLE), never UP.
# c4's "status == UP" can never pass here, and its C6 "left UP" would pass
# vacuously. c4b asserts the peer protocol directly instead:
#   C4' exactly 3 nodes READY with version NO_GPU, pairwise CONNECTED, 15 slots
#       UNAVAILABLE, total 18; domain status DEGRADED.
#   C5  as in c4 (CD Ready, one clique object with worker7..9 Ready, channel0 char dev major 255).
#   C6' delete worker9's daemon: worker7's READY count drops below 3, then returns to 3.
# Also re-runs c2's post-checks (c2 stopped at its helm --wait).
set -uo pipefail
LOG="${HOME}/mokka-hetero/logs/h8-c4b-cd-check-dns.log"
exec > >(tee "${LOG}") 2>&1
NS=mokka-hetero-cd; DRV=nvidia
WANT_CLIQUE="00000000-0000-0000-0000-000000000001.32766"
read -r CH_MAJOR _ < "${HOME}/mokka-hetero/tmp/h8-imex-majors.txt"
echo "start $(date -u +%FT%TZ) channel major=${CH_MAJOR}"
fail=0; pass() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fail=1; }
# RUN_C6=0 skips the destructive C6' (used for mutant runs aimed at C4'/C5).
RUN_C6="${RUN_C6:-1}"
imexctl() { kubectl -n "${DRV}" exec "$1" -c compute-domain-daemon -- nvidia-imex-ctl -c /imexd/imexd.cfg "${@:2}"; }
uid="$(kubectl -n "${NS}" get computedomain vr200-cd -o jsonpath='{.metadata.uid}')"
d7="$(kubectl -n "${DRV}" get pods -l "resource.nvidia.com/computeDomain=${uid}" --field-selector spec.nodeName=mokka-hetero-worker7 -o jsonpath='{.items[0].metadata.name}')"
echo "uid=${uid} d7=${d7}"
ready_count() { imexctl "$1" -N -j 2>/dev/null | jq '[.nodes[] | select(.status=="READY" and .version=="NO_GPU")] | length' 2>/dev/null; }

echo "== C4' IMEX domain in DNS-names mode (view from every daemon)"
mapfile -t daemons < <(kubectl -n "${DRV}" get pods -l "resource.nvidia.com/computeDomain=${uid}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
for d in "${daemons[@]}"; do
  j="$(imexctl "${d}" -N -j 2>/dev/null)"
  echo "${d}: $(jq -c '{status, ready: [.nodes | to_entries[] | select(.value.status=="READY") | "\(.key)=\(.value.host)/\(.value.version)"] | sort, unavailable: ([.nodes[] | select(.status=="UNAVAILABLE")] | length), total: (.nodes | length)}' <<< "${j}")"
  r="$(jq '[.nodes[] | select(.status=="READY" and .version=="NO_GPU")] | length' <<< "${j}")"
  u="$(jq '[.nodes[] | select(.status=="UNAVAILABLE")] | length' <<< "${j}")"
  t="$(jq '.nodes | length' <<< "${j}")"
  s="$(jq -r '.status' <<< "${j}")"
  # pairwise: every READY node's connections to every READY node are CONNECTED
  pw="$(jq '[.nodes | to_entries[] | select(.value.status=="READY") | .key] as $r
            | [.nodes | to_entries[] | select(.value.status=="READY") | .value.connections as $c | $r[] | $c[.].status]
            | (length == ($r|length)*($r|length)) and all(.=="CONNECTED")' <<< "${j}")"
  [[ "${r}" -eq 3 && "${u}" -eq 15 && "${t}" -eq 18 && "${s}" == "DEGRADED" && "${pw}" == "true" ]] \
    && pass "C4' ${d}: 3 READY NO_GPU pairwise CONNECTED, 15 UNAVAILABLE of 18 slots, status DEGRADED" \
    || bad "C4' ${d}: ready=${r} unavailable=${u} total=${t} status=${s} pairwise=${pw}"
done
imexctl "${d7}" -N 2>/dev/null | sed -n '/^Nodes:/,/^Domain State/p' | grep -E 'Node #[0-2] |From|^ +[0-2] |Domain State'

echo "== C5 API objects"
[[ "$(kubectl -n "${NS}" get computedomain vr200-cd -o jsonpath='{.status.status}')" == "Ready" ]] && pass "C5 ComputeDomain Ready (necessary, not sufficient)" || bad "C5 CD not Ready: $(kubectl -n "${NS}" get computedomain vr200-cd -o jsonpath='{.status}')"
kubectl -n "${DRV}" get computedomaincliques -o json | jq -r --arg u "${uid}" '.items[] | select(.metadata.name|startswith($u)) | "\(.metadata.name) \([.daemons[]? | "\(.nodeName)=\(.status)"] | sort | join(","))"' | tee /tmp/h8-cdclique.txt
[[ "$(wc -l < /tmp/h8-cdclique.txt)" -eq 1 ]] && grep -q "^${uid}.${WANT_CLIQUE} mokka-hetero-worker7=Ready,mokka-hetero-worker8=Ready,mokka-hetero-worker9=Ready$" /tmp/h8-cdclique.txt \
  && pass "C5 clique ${uid}.${WANT_CLIQUE} holds worker7..9 Ready" || bad "C5 clique objects: $(cat /tmp/h8-cdclique.txt)"
want_major="$(printf '%x' "${CH_MAJOR}")"
for p in $(kubectl -n "${NS}" get pods -l app=vr200-cd-workload -o jsonpath='{.items[*].metadata.name}'); do
  st="$(kubectl -n "${NS}" exec "${p}" -- stat -c '%F %t %T' /dev/nvidia-caps-imex-channels/channel0 2>&1)"
  [[ "${st}" == "character special file ${want_major} 0" ]] && pass "C5 ${p} channel0 '${st}' (mock major ${CH_MAJOR})" || bad "C5 ${p} channel0 '${st}' want 'character special file ${want_major} 0'"
done

if [[ "${RUN_C6}" == 1 ]]; then
echo "== C6' liveness: delete the worker9 daemon; worker7's READY count must drop below 3, then return to 3"
before="$(ready_count "${d7}")"; echo "READY before=${before}"
[[ "${before}" -eq 3 ]] || bad "C6' precondition READY=${before}"
d9="$(kubectl -n "${DRV}" get pods -l "resource.nvidia.com/computeDomain=${uid}" --field-selector spec.nodeName=mokka-hetero-worker9 -o name)"
echo "deleting ${d9} at $(date -u +%T)"
kubectl -n "${DRV}" delete "${d9}" --wait=false
low=""; for _ in $(seq 1 40); do c="$(ready_count "${d7}")"; if [[ -n "${c}" && "${c}" -lt 3 ]]; then low="${c}"; break; fi; sleep 2; done
[[ -n "${low}" ]] && pass "C6' READY dropped to ${low} after peer loss ($(date -u +%T))" || bad "C6' READY stayed 3 with a peer deleted"
back=""; for _ in $(seq 1 90); do c="$(ready_count "${d7}")"; [[ "${c}" == "3" ]] && { back=1; break; }; sleep 3; done
[[ -n "${back}" ]] && pass "C6' READY back to 3 after the DaemonSet replaced the daemon ($(date -u +%T))" || bad "C6' READY did not return to 3 (last=${c})"
kubectl -n "${DRV}" get pods -l "resource.nvidia.com/computeDomain=${uid}" -o wide
else echo "== C6' SKIPPED (RUN_C6=${RUN_C6})"; fi

echo "== c2 post-checks (c2 stopped at helm --wait)"
helm history nvidia-dra-driver -n nvidia | tail -3
kubectl -n nvidia get pods -o wide
[[ "$(kubectl get nodes -l 'nvml-mock/profile,nvidia.com/gpu.clique' -o name | wc -l)" -eq 0 ]] && pass "no real node has nvidia.com/gpu.clique" || bad "a real node got a clique label"
a="$(kubectl get resourceslices -o json | jq -r '[.items[] | select(.spec.driver=="gpu.nvidia.com" and (.spec.nodeName|startswith("mokka-hetero-")))] | map(.spec.devices|length) | add')"
[[ "${a}" == "48" ]] && pass "real-tier GPU devices 48" || bad "real-tier GPU devices ${a}"
kubectl get resourceslices -o json | jq -r '[.items[] | select(.spec.driver=="gpu.nvidia.com" and (.spec.nodeName|startswith("mokka-hetero-"))) | .spec.devices[] | "\(.attributes.productName.string)|\(.attributes.architecture.string)"] | group_by(.) | map("\(length)x \(.[0])") | .[]'
kubectl get resourceslices -o json | jq -r '[.items[] | select(.spec.driver=="compute-domain.nvidia.com") | .spec.nodeName] | unique | "compute-domain slices on: \(join(","))"'
for n in $(kind get nodes --name mokka-hetero | sort); do
  c="$(docker exec "${n}" sh -c 'ls -d /dev/nvidia* 2>/dev/null | wc -l')"; [[ "${c}" -eq 0 ]] || bad "${n} leaked host GPU nodes: ${c}"
done && echo "checked /dev/nvidia* on all kind nodes"
for n in $(kind get nodes --name mokka-hetero | sort); do echo "${n} $(docker inspect -f '{{.State.StartedAt}} {{.RestartCount}}' "${n}")"; done > /tmp/h8-node-starts-after.txt
cmp -s /tmp/h8-node-starts-before.txt /tmp/h8-node-starts-after.txt && pass "no kind node container restarted" || { bad "node start times changed"; diff /tmp/h8-node-starts-before.txt /tmp/h8-node-starts-after.txt; }
echo "L4 compute apps:"; nvidia-smi --query-compute-apps=pid --format=csv
[[ "$(nvidia-smi --query-compute-apps=pid --format=csv,noheader | wc -l)" -eq 0 ]] && pass "real L4 has no compute apps" || bad "real L4 has compute apps"
echo "DONE fail=${fail} $(date -u +%FT%TZ)"
exit "${fail}"
