#!/bin/bash
# H3 step 4a: clone ResourceSlices onto the 54 KWOK nodes with H2's
# clone-slices.sh, one real source per type. Sources are real nodes H4 is NOT
# using (worker2 h100, worker5 gb300, worker8 vr200); all real nodes of a type
# publish the same slice (H1 step 7). Refuses a source whose profile label or
# identity tuple is not the expected one, and checks afterwards that the real
# slices were not written (same names and resourceVersions).
set -uo pipefail
H2="${HOME}/mokka-hetero/h2"
OUT="${HOME}/mokka-hetero/out/h3"
LOG="${HOME}/mokka-hetero/logs/h3-s4a-clone.log"
mkdir -p "${OUT}"
exec > >(tee "${LOG}") 2>&1
echo "start $(date -u +%FT%TZ)"

declare -A SRC=([vr200]=mokka-hetero-worker8 [gb300]=mokka-hetero-worker5 [h100]=mokka-hetero-worker2)
declare -A WANT=(
  [vr200]="4 NVIDIA Graphics Device|Rubin|10.7.0"
  [gb300]="4 NVIDIA GB300 NVL|Blackwell|10.0.0"
  [h100]="8 NVIDIA H100 80GB HBM3|Hopper|9.0.0"
)
real_state() {
  kubectl get resourceslices -o json |
    jq -c '[.items[] | select(.spec.nodeName | startswith("mokka-hetero-")) | {n: .metadata.name, rv: .metadata.resourceVersion}] | sort_by(.n)'
}

fail=0
for t in vr200 gb300 h100; do
  s="${SRC[${t}]}"
  prof="$(kubectl get node "${s}" -o json | jq -r '.metadata.labels["nvml-mock/profile"] // "<none>"')"
  tuple="$(kubectl get resourceslices -o json | jq -r --arg n "${s}" '[.items[] | select(.spec.nodeName == $n and .spec.driver == "gpu.nvidia.com") | .spec.devices[] | "\(.attributes.productName.string)|\(.attributes.architecture.string)|\(.attributes.cudaComputeCapability.version)"] | group_by(.) | map("\(length) \(.[0])") | join("; ")')"
  echo "source ${t}: ${s} profile=${prof} tuple=[${tuple}]"
  if [[ "${prof}" != "${t}" || "${tuple}" != "${WANT[${t}]}" ]]; then
    echo "FAIL source ${s} is not a ${t} (want profile ${t}, tuple [${WANT[${t}]}])"; fail=1
  fi
done
[[ ${fail} -eq 0 ]] || { echo "DONE fail=1 (sources)"; exit 1; }

before="$(real_state)"
echo "real slices before: $(jq -r 'map("\(.n)@\(.rv)") | join(" ")' <<<"${before}")"

for t in vr200 gb300 h100; do
  echo "== clone ${t} from ${SRC[${t}]}"
  bash "${H2}/dra/clone-slices.sh" "${t}" "${SRC[${t}]}" 2>&1 |
    sed -E 's/^(resourceslice\.resource\.k8s\.io\/kwok-[a-z0-9]+)-[0-9]+(-gpu\.nvidia\.com) /\1-NN\2 /' | sort | uniq -c
  rc=${PIPESTATUS[0]}; echo "clone ${t} rc=${rc}"
  [[ ${rc} -eq 0 ]] || fail=1
done

after="$(real_state)"
if [[ "${before}" == "${after}" ]]; then
  echo "PASS real slices untouched (same 9 names and resourceVersions)"
else
  echo "FAIL real slices changed during cloning"; echo "after: ${after}"; fail=1
fi
kubectl get resourceslices -o json >"${OUT}/slices-s4.json"
kubectl get nodes -o json >"${OUT}/nodes-s4.json"
kubectl get sgpuracks.mokka.nvidia.com -o json >"${OUT}/racks-s4.json"
echo "DONE fail=${fail} $(date -u +%FT%TZ)"
exit "${fail}"
