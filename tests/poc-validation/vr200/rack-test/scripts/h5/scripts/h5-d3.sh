#!/bin/bash
# D3 detection mutation on mokka-hetero-worker9, one phase per call:
#   pre     record worker9's slice and node-container state; identity check must be GREEN
#   flip    vr200 -> gb300: identity check must go RED (Rubin 80, Blackwell 88)
#   revert  gb300 -> vr200: identity check GREEN again, worker9 slice equal to pre
# The relabel is done in two steps (remove the label, wait for the old nvml-mock
# pod to be gone, then set the new value): node-agent runs Revoke -> Discard on
# shutdown (internal/agent/agent.go:104-109) and Discard deletes driver/dev,
# driver/usr/lib64 and config/config.yaml under the shared hostPath
# (internal/agent/gpudriver/gpudriver.go:75-110). With a one-step relabel the old
# pod's teardown could overlap the new pod's Stage on the same tree (INFERENCE,
# not reproduced). Then the DRA kubelet-plugin pod on worker9 is deleted so its
# DaemonSet recreates it and it re-reads NVML.
# Exit status: pre/revert 0 only if the identity check passes; flip 0 only if it FAILS.
set -uo pipefail
PHASE="${1:?pre|flip|revert}"
N=mokka-hetero-worker9
OUT="${HOME}/mokka-hetero/out/h5/d3"
LOG="${HOME}/mokka-hetero/logs/h5-d3-${PHASE}.log"
mkdir -p "${OUT}"
exec > >(tee "${LOG}") 2>&1
ts() { date -u +%H:%M:%SZ; }
label() { kubectl get node "${N}" -o json | jq -r '.metadata.labels["nvml-mock/profile"] // "<none>"'; }
mockpods() {
  kubectl -n mokka get pods -o json | jq -r --arg n "${N}" '.items[] | select(.spec.nodeName == $n and ((.metadata.ownerReferences // [])[0].kind == "DaemonSet"))
    | "\(.metadata.ownerReferences[0].name) \(.metadata.name) phase=\(.status.phase) ready=\([.status.conditions[]? | select(.type == "Ready") | .status][0]) deleting=\(.metadata.deletionTimestamp != null)"'
}
plugin() {
  kubectl -n nvidia get pods -o json | jq -r --arg n "${N}" '.items[] | select(.spec.nodeName == $n and (.metadata.name | startswith("dra-driver-nvidia-gpu-kubelet-plugin-")))
    | "\(.metadata.name) phase=\(.status.phase) ready=\([.status.conditions[]? | select(.type == "Ready") | .status][0]) deleting=\(.metadata.deletionTimestamp != null)"'
}
slice9() {
  kubectl get resourceslices -o json | jq -r --arg n "${N}" '.items[] | select(.spec.driver == "gpu.nvidia.com" and .spec.nodeName == $n)
    | "\(.metadata.name) poolgen=\(.spec.pool.generation) devices=\(.spec.devices | length) \([.spec.devices[] | "\(.attributes.productName.string)|\(.attributes.architecture.string)|\(.attributes.cudaComputeCapability.version)|drv \(.attributes.driverVersion.version)"] | group_by(.) | map("\(length)x \(.[0])") | join(" + "))"'
}
tuple9() {
  kubectl get resourceslices -o json | jq -r --arg n "${N}" '[.items[] | select(.spec.driver == "gpu.nvidia.com" and .spec.nodeName == $n) | .spec.devices[]
    | "\(.attributes.productName.string)|\(.attributes.architecture.string)|\(.attributes.cudaComputeCapability.version)"] | group_by(.) | map("\(length) \(.[0])") | join(" + ")'
}
containers() {
  for n in $(kind get nodes --name mokka-hetero | sort); do
    echo "${n} $(docker inspect "${n}" --format '{{.RestartCount}} {{.State.StartedAt}}') dev-nvidia=$(docker exec "${n}" sh -c 'ls -d /dev/nvidia* 2>/dev/null | wc -l')"
  done
}
state() {
  echo "-- $(ts) state: label nvml-mock/profile=$(label)"
  echo "   mock pods on ${N}: $(mockpods | paste -sd';')"
  echo "   plugin pod: $(plugin)"
  echo "   slice: $(slice9)"
}
wait_mock() { # <daemonset name or none> <timeout>
  local want="$1" to="$2" start cur
  start="$(date +%s)"
  while :; do
    cur="$(mockpods)"
    if [[ "${want}" == "none" ]]; then [[ -z "${cur}" ]] && break
    else [[ "$(grep -c . <<<"${cur}")" == "1" && "${cur}" == "${want} "*"phase=Running ready=True deleting=false" ]] && break; fi
    (( $(date +%s) - start >= to )) && { echo "$(ts) TIMEOUT wait_mock ${want}: ${cur}"; return 1; }
    sleep 2
  done
  echo "$(ts) wait_mock ${want}: reached after $(( $(date +%s) - start ))s ${cur}"
}
restart_plugin() {
  local old start cur
  old="$(plugin | awk '{print $1}')"
  echo "$(ts) deleting plugin pod ${old}"
  kubectl -n nvidia delete pod "${old}" --wait=true
  start="$(date +%s)"
  while :; do
    cur="$(plugin)"
    [[ -n "${cur}" && "${cur}" != "${old} "* && "${cur}" == *"ready=True deleting=false" ]] && break
    (( $(date +%s) - start >= 180 )) && { echo "$(ts) TIMEOUT plugin: ${cur}"; return 1; }
    sleep 2
  done
  echo "$(ts) new plugin pod ready after $(( $(date +%s) - start ))s: ${cur}"
}
wait_tuple() { # <expected tuple9 output> <timeout>
  local want="$1" to="$2" start cur
  start="$(date +%s)"
  while :; do
    cur="$(tuple9)"
    [[ "${cur}" == "${want}" ]] && break
    (( $(date +%s) - start >= to )) && { echo "$(ts) TIMEOUT slice: [${cur}] want [${want}]"; return 1; }
    sleep 3
  done
  echo "$(ts) worker9 slice is [${cur}] after $(( $(date +%s) - start ))s"
}
relabel() { # <new profile>
  local to="$1" from
  from="$(label)"
  echo "$(ts) step 1: kubectl label node ${N} nvml-mock/profile- (was ${from})"
  kubectl label node "${N}" nvml-mock/profile-
  wait_mock none 300 || return 1
  echo "$(ts) step 2: kubectl label node ${N} nvml-mock/profile=${to}"
  kubectl label node "${N}" "nvml-mock/profile=${to}"
  wait_mock "nvml-mock-${to}" 300 || return 1
  local p; p="$(mockpods | awk '{print $2}')"
  echo "   node-agent log (${p}), staging lines:"
  kubectl -n mokka logs "${p}" 2>&1 | grep -E '"msg":"(simulator staged|agent started|discarding simulator)' | cut -c1-200 | head -8
}

echo "start ${PHASE} $(date -u +%FT%TZ)"
containers > "${OUT}/containers-${PHASE}.txt"; cat "${OUT}/containers-${PHASE}.txt"
state
case "${PHASE}" in
  pre)
    kubectl get resourceslices -o json | jq -S --arg n "${N}" '[.items[] | select(.spec.driver == "gpu.nvidia.com" and .spec.nodeName == $n) | .spec.devices] ' > "${OUT}/worker9-devices-pre.json"
    echo "saved ${OUT}/worker9-devices-pre.json sha256=$(sha256sum < "${OUT}/worker9-devices-pre.json" | cut -c1-16)"
    bash "${HOME}/mokka-hetero/h5/check-identity.sh"; rc=$?
    echo "D3 pre: identity check rc=${rc} (want 0)"
    exit "${rc}" ;;
  flip)
    relabel gb300 || { echo "ABORT relabel"; exit 2; }
    restart_plugin || { echo "ABORT plugin"; exit 2; }
    wait_tuple "4 NVIDIA GB300 NVL|Blackwell|10.0.0" 180
    state
    bash "${HOME}/mokka-hetero/h5/check-identity.sh"; rc=$?
    echo "D3 flip: identity check rc=${rc} (want non-zero)"
    [[ ${rc} -ne 0 ]] ;;
  revert)
    relabel vr200 || { echo "ABORT relabel"; exit 2; }
    restart_plugin || { echo "ABORT plugin"; exit 2; }
    wait_tuple "4 NVIDIA Graphics Device|Rubin|10.7.0" 180
    state
    kubectl get resourceslices -o json | jq -S --arg n "${N}" '[.items[] | select(.spec.driver == "gpu.nvidia.com" and .spec.nodeName == $n) | .spec.devices] ' > "${OUT}/worker9-devices-revert.json"
    # Compare the device SET: dra-driver v0.5.0 builds the slice by ranging over
    # Go maps (cmd/gpu-kubelet-plugin/driver.go:489-495, allocatable.go:42-44), so
    # the list order changes on every plugin restart. The first revert run
    # compared order too and failed on order alone.
    diff <(jq -S '.[0] | sort_by(.name)' "${OUT}/worker9-devices-pre.json") \
         <(jq -S '.[0] | sort_by(.name)' "${OUT}/worker9-devices-revert.json"); drc=$?
    echo "worker9 devices pre vs revert (sorted by name): diff rc=${drc} (want 0)"
    diff "${OUT}/containers-pre.txt" "${OUT}/containers-revert.txt"; crc=$?
    echo "kind node containers pre vs revert (restarts, startedAt, dev-nvidia): diff rc=${crc} (want 0; else run scripts/s3b-hide-host-gpu.sh --restart)"
    bash "${HOME}/mokka-hetero/h5/check-identity.sh"; rc=$?
    echo "D3 revert: identity check rc=${rc} (want 0)"
    [[ ${rc} -eq 0 && ${drc} -eq 0 && ${crc} -eq 0 ]] ;;
esac
