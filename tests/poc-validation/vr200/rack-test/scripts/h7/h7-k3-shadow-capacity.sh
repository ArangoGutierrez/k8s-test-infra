#!/bin/bash
# H6 Kueue step 3: give every KWOK node the accounting resource Kueue TAS
# counts, with the value read from that node's own DRA ResourceSlice, never
# typed in. Kueue TAS reads node allocatable only
# (tas_topology_tree.go:167) and cannot see DRA devices; this resource is the
# bridge, and it is only honest while it equals the slice's device count.
# The script therefore sets it FROM the slice and then re-checks equality.
#
# Resource per type: mokka-hetero.nvidia.com/tas-<type>-gpu. Not nvidia.com/gpu:
# a node that advertises nvidia.com/gpu in allocatable is served by the
# device-plugin path instead of DRA (k8s v1.36.1 noderesources/fit.go:270-292),
# and the DRA chart maps nvidia.com/gpu to gpu.nvidia.com (deviceclass-gpu.yaml:12-14).
#
# KWOK nodes only: capacity AND allocatable are patched (the kwok stages keep
# them: stage-fast node-initialize echoes them at :107-122, node-heartbeat
# never writes them). Real nodes are outside the TAS flavor (no clique label)
# and are not touched; on a real node the kubelet would drop an
# allocatable-only key (k8s nodestatus/setters.go:297-315).
set -uo pipefail
cd "$(dirname "$0")" || exit 1
LOG="${HOME}/mokka-hetero/logs/h7-k3-shadow-capacity.log"
mkdir -p "$(dirname "${LOG}")"
exec > >(tee "${LOG}") 2>&1
echo "start $(date -u +%FT%TZ)"
fail=0

kubectl get resourceslices -o json > /tmp/h7-slices.json
kubectl get nodes -o json > /tmp/h7-nodes.json

# node -> device count of driver gpu.nvidia.com slices bound to it
jq -r '[.items[] | select(.spec.driver=="gpu.nvidia.com" and .spec.nodeName != null)
        | {n: .spec.nodeName, c: (.spec.devices | length)}]
       | group_by(.n) | .[] | "\(.[0].n) \(map(.c) | add)"' /tmp/h7-slices.json > /tmp/h7-slice-counts.txt

while read -r node gtype; do
  count="$(awk -v n="${node}" '$1==n{print $2}' /tmp/h7-slice-counts.txt)"
  if [[ -z "${count}" || "${count}" -le 0 ]]; then
    echo "FAIL ${node}: no gpu.nvidia.com slice devices"; fail=1; continue
  fi
  res="mokka-hetero.nvidia.com/tas-${gtype}-gpu"
  kubectl patch node "${node}" --subresource=status --type=merge \
    -p "{\"status\":{\"capacity\":{\"${res}\":\"${count}\"},\"allocatable\":{\"${res}\":\"${count}\"}}}" > /dev/null
  rc=$?; [[ ${rc} -eq 0 ]] || { echo "FAIL patch ${node} rc=${rc}"; fail=1; }
done < <(jq -r '.items[] | select(.metadata.labels["type"]=="kwok") |
                "\(.metadata.name) \(.metadata.labels["mokka-hetero.nvidia.com/gpu-type"])"' /tmp/h7-nodes.json)

sleep 5
kubectl get nodes -o json > /tmp/h7-nodes-after.json
echo "== verify: allocatable == slice devices on every KWOK node; no tas-* on real nodes"
jq -r --rawfile counts /tmp/h7-slice-counts.txt '
  ($counts | split("\n") | map(select(length>0) | split(" ")) | map({(.[0]): (.[1]|tonumber)}) | add) as $c
  | .items[]
  | (.metadata.labels["mokka-hetero.nvidia.com/gpu-type"] // "") as $t
  | ([.status.allocatable | to_entries[] | select(.key|startswith("mokka-hetero.nvidia.com/tas-"))]) as $tas
  | if .metadata.labels["type"]=="kwok" then
      (if ($tas|length)==1 and $tas[0].key==("mokka-hetero.nvidia.com/tas-"+$t+"-gpu") and ($tas[0].value|tonumber)==$c[.metadata.name]
       then "PASS \(.metadata.name) \($tas[0].key)=\($tas[0].value) slice=\($c[.metadata.name])"
       else "FAIL \(.metadata.name) tas=\($tas|tostring) slice=\($c[.metadata.name])" end)
    else
      (if ($tas|length)==0 then "PASS \(.metadata.name) real/control node carries no tas-* resource"
       else "FAIL \(.metadata.name) real node carries \($tas|tostring)" end)
    end' /tmp/h7-nodes-after.json | tee /tmp/h7-shadow-verify.txt | sort | uniq -c -w 4
grep -q '^FAIL' /tmp/h7-shadow-verify.txt && { grep '^FAIL' /tmp/h7-shadow-verify.txt; fail=1; }
echo "kwok nodes verified: $(grep -c '^PASS kwok-' /tmp/h7-shadow-verify.txt) (want 54)"
[[ "$(grep -c '^PASS kwok-' /tmp/h7-shadow-verify.txt)" -eq 54 ]] || fail=1
# The merge patch names only capacity/allocatable, so H3's preset InternalIPs
# (172.18.250.x, which keep kindnetd alive: H3 step 2a) must be untouched.
ipbad="$(jq -r '.items[] | select(.metadata.labels["type"]=="kwok")
  | ([.status.addresses[]? | select(.type=="InternalIP") | .address] | first // "none") as $ip
  | select($ip | startswith("172.18.250.") | not) | "\(.metadata.name) \($ip)"' /tmp/h7-nodes-after.json)"
[[ -z "${ipbad}" ]] && echo "PASS all KWOK InternalIPs still 172.18.250.x" || { echo "FAIL InternalIP changed: ${ipbad}"; fail=1; }
echo "DONE fail=${fail} $(date -u +%FT%TZ)"
exit "${fail}"
