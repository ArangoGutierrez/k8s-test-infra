#!/bin/bash
# Step 7: verification. Exits non-zero if any worker's published device count
# differs from its profile's (h100 -> 8, gb300/vr200 -> 4), if a worker has no
# slice, or if the control plane / CRDs are missing.
set -uo pipefail
CTX=kind-mokka-hetero
OUT=~/mokka-hetero/out
mkdir -p "${OUT}"
k() { kubectl --context "${CTX}" "$@"; }
fail=0

echo "== kubectl get nodes -L nvml-mock/profile"
k get nodes -L nvml-mock/profile

echo "== kubectl get resourceslices -o wide"
k get resourceslices -o wide

echo "== per-node device count (sum over every slice on the node)"
k get resourceslices -o json > "${OUT}/resourceslices-all.json"
jq -r '[.items[] | {node: .spec.nodeName, driver: .spec.driver, n: ((.spec.devices // []) | length)}]
  | group_by(.node)[] | "\(.[0].node)\t\(map(.driver) | unique | join(","))\tslices=\(length)\tdevices=\(map(.n) | add)"' \
  "${OUT}/resourceslices-all.json"

echo "== expected vs actual per worker"
while read -r node profile; do
  case "${profile}" in
    h100) want=8 ;;
    gb300|vr200) want=4 ;;
    *) echo "FAIL ${node}: unknown profile '${profile}'"; fail=1; continue ;;
  esac
  got=$(jq --arg n "${node}" '[.items[] | select(.spec.nodeName == $n) | (.spec.devices // []) | length] | add // 0' "${OUT}/resourceslices-all.json")
  if [ "${got}" = "${want}" ]; then
    echo "PASS ${node} profile=${profile} devices=${got}"
  else
    echo "FAIL ${node} profile=${profile} devices=${got} want=${want}"; fail=1
  fi
done < <(k get nodes -l nvml-mock/profile -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.labels.nvml-mock/profile}{"\n"}{end}')

echo "== one ResourceSlice set per type (first node per profile, sorted)"
for p in h100 gb300 vr200; do
  node=$(k get nodes -l "nvml-mock/profile=${p}" -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | sort | head -1)
  k get resourceslices --field-selector "spec.nodeName=${node}" -o yaml > "${OUT}/resourceslice-${p}.yaml"
  k get resourceslices --field-selector "spec.nodeName=${node}" -o json > "${OUT}/resourceslice-${p}.json"
  echo "${p} -> ${node} -> ${OUT}/resourceslice-${p}.yaml ($(grep -c 'name: gpu-' "${OUT}/resourceslice-${p}.yaml") gpu-* device names)"
done

echo "== Mokka control plane"
k -n mokka get deploy,pods -l app.kubernetes.io/component=control-plane -o wide
ready=$(k -n mokka get pods -l app.kubernetes.io/component=control-plane -o jsonpath='{range .items[*]}{.status.phase}{"/"}{.status.containerStatuses[0].ready}{"\n"}{end}')
echo "control-plane phase/ready: ${ready}"
echo "${ready}" | grep -qx 'Running/true' || { echo "FAIL control plane not Running/ready"; fail=1; }

echo "== kubectl get crd | grep mokka"
k get crd | grep mokka || { echo "FAIL no mokka CRDs"; fail=1; }
[ "$(k get crd | grep -c mokka)" = 4 ] || { echo "FAIL expected 4 mokka CRDs"; fail=1; }

echo "VERIFY fail=${fail}"
exit "${fail}"
