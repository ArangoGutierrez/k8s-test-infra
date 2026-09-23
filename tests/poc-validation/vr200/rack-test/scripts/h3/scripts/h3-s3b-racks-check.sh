#!/bin/bash
# H3 step 3b: rack checks on fresh dumps, then mutation-verify every guard
# against altered COPIES of the dumps (the cluster is never mutated).
# Exits non-zero if a live check fails or a mutant is not caught.
set -uo pipefail
H3="${HOME}/mokka-hetero/h3"
OUT="${HOME}/mokka-hetero/out/h3"
M="${OUT}/mutants"
LOG="${HOME}/mokka-hetero/logs/h3-s3b-racks-check.log"
mkdir -p "${M}"
exec > >(tee "${LOG}") 2>&1
echo "start $(date -u +%FT%TZ)"

kubectl get nodes -o json >"${OUT}/nodes-s3b.json"
kubectl get sgpuracks.mokka.nvidia.com -o json >"${OUT}/racks-s3b.json"
kubectl get resourceslices -o json >"${OUT}/slices-s3b.json"

run_check() {  # nodes racks slices -> output on stdout
  jq -r --slurpfile racks "$2" --slurpfile slices "$3" -f "${H3}/check-racks.jq" "$1"
}

echo "== kubectl get sgpuinventories,sgpuracks"
kubectl get sgpuinventories,sgpuracks
echo "== live checks"
live="$(run_check "${OUT}/nodes-s3b.json" "${OUT}/racks-s3b.json" "${OUT}/slices-s3b.json")"; rc=$?
echo "${live}"
nfail="$(grep -c '^FAIL' <<<"${live}")"; npass="$(grep -c '^PASS' <<<"${live}")"
echo "live: jq rc=${rc} PASS=${npass} FAIL=${nfail} (want 19 PASS, 0 FAIL)"
fail=0
[[ ${rc} -eq 0 && "${nfail}" == "0" && "${npass}" == "19" ]] || fail=1

echo "== per type: nvidia.com/gpu.clique values on the 18 fake nodes, and sgpu-assigned count"
for t in vr200 gb300 h100; do
  echo "-- ${t}"
  kubectl get nodes -l "type=kwok,mokka-hetero.nvidia.com/gpu-type=${t}" -o json |
    jq -r '.items[] | .metadata.labels["nvidia.com/gpu.clique"] // "<none>"' | sort | uniq -c
  echo "   sgpu-assigned=true: $(kubectl get nodes -l "type=kwok,mokka-hetero.nvidia.com/gpu-type=${t},mokka.nvidia.com/sgpu-assigned=true" --no-headers | wc -l)"
done
echo "-- real nodes with a clique label: $(kubectl get nodes -l 'nvidia.com/gpu.clique,!type' --no-headers 2>/dev/null | wc -l)"
echo "-- example assignment annotation (kwok-vr200-00):"
kubectl get node kwok-vr200-00 -o jsonpath='{.metadata.annotations.mokka\.nvidia\.com/sgpu-assignment}{"\n"}'

# ------------------------------------------------------------ mutants
vr_clique_gb="$(jq -r '[.items[] | select(.metadata.labels["mokka-hetero.nvidia.com/gpu-type"]=="gb300")][0].metadata.labels["nvidia.com/gpu.clique"]' "${OUT}/nodes-s3b.json")"
vr_clique="$(jq -r '[.items[] | select(.metadata.labels["mokka-hetero.nvidia.com/gpu-type"]=="vr200")][0].metadata.labels["nvidia.com/gpu.clique"]' "${OUT}/nodes-s3b.json")"

mutant() {  # name expected-FAIL-regex nodes racks slices "field probe jq (applied to the mutant file)" file
  local name="$1" want="$2" n="$3" r="$4" s="$5"
  local out; out="$(run_check "${n}" "${r}" "${s}")"
  local f; f="$(grep '^FAIL' <<<"${out}")"
  if grep -qE "${want}" <<<"${f}"; then echo "KILLED ${name}: ${f//$'\n'/ | }"
  else echo "SURVIVED ${name}: want /${want}/ got: ${f:-no FAIL}"; fail=1; fi
}
probe() { jq -r "$1" "$2"; }

# M1: one VR200 tray carries the GB300 clique
jq --arg v "${vr_clique_gb}" '(.items[] | select(.metadata.name=="kwok-vr200-05") | .metadata.labels["nvidia.com/gpu.clique"]) |= $v' "${OUT}/nodes-s3b.json" >"${M}/m1-nodes.json"
echo "M1 kwok-vr200-05 clique: $(probe '.items[] | select(.metadata.name=="kwok-vr200-05") | .metadata.labels["nvidia.com/gpu.clique"]' "${OUT}/nodes-s3b.json") -> $(probe '.items[] | select(.metadata.name=="kwok-vr200-05") | .metadata.labels["nvidia.com/gpu.clique"]' "${M}/m1-nodes.json")"
mutant M1 '^FAIL vr200: clique values' "${M}/m1-nodes.json" "${OUT}/racks-s3b.json" "${OUT}/slices-s3b.json"

# M2: one H100 node loses sgpu-assigned
jq '(.items[] | select(.metadata.name=="kwok-h100-03") | .metadata.labels) |= del(.["mokka.nvidia.com/sgpu-assigned"])' "${OUT}/nodes-s3b.json" >"${M}/m2-nodes.json"
echo "M2 kwok-h100-03 sgpu-assigned: $(probe '.items[] | select(.metadata.name=="kwok-h100-03") | .metadata.labels["mokka.nvidia.com/sgpu-assigned"] // "<absent>"' "${OUT}/nodes-s3b.json") -> $(probe '.items[] | select(.metadata.name=="kwok-h100-03") | .metadata.labels["mokka.nvidia.com/sgpu-assigned"] // "<absent>"' "${M}/m2-nodes.json")"
mutant M2 '^FAIL h100: sgpu-assigned count 17' "${M}/m2-nodes.json" "${OUT}/racks-s3b.json" "${OUT}/slices-s3b.json"

# M3: a real VR200 worker carries the VR200 rack clique (H2 precondition P2)
jq --arg v "${vr_clique}" '(.items[] | select(.metadata.name=="mokka-hetero-worker7") | .metadata.labels["nvidia.com/gpu.clique"]) |= $v' "${OUT}/nodes-s3b.json" >"${M}/m3-nodes.json"
echo "M3 worker7 clique: $(probe '.items[] | select(.metadata.name=="mokka-hetero-worker7") | .metadata.labels["nvidia.com/gpu.clique"] // "<absent>"' "${OUT}/nodes-s3b.json") -> $(probe '.items[] | select(.metadata.name=="mokka-hetero-worker7") | .metadata.labels["nvidia.com/gpu.clique"] // "<absent>"' "${M}/m3-nodes.json")"
mutant M3 '^FAIL real nodes 10, projected onto \["mokka-hetero-worker7"\]' "${M}/m3-nodes.json" "${OUT}/racks-s3b.json" "${OUT}/slices-s3b.json"

# M4: one VR200 rack slot's pciAddress no longer matches the real slice
jq '(.items[] | select(.spec.identity.rackGroup=="vr200") | .spec.nodes[0].gpus[1].pciAddress) |= "0002:c2:00.0"' "${OUT}/racks-s3b.json" >"${M}/m4-racks.json"
echo "M4 vr200 rack node0 gpu1 pciAddress: $(probe '.items[] | select(.spec.identity.rackGroup=="vr200") | .spec.nodes[0].gpus[1].pciAddress' "${OUT}/racks-s3b.json") -> $(probe '.items[] | select(.spec.identity.rackGroup=="vr200") | .spec.nodes[0].gpus[1].pciAddress' "${M}/m4-racks.json")"
mutant M4 '^FAIL vr200: rack pciAddress' "${OUT}/nodes-s3b.json" "${M}/m4-racks.json" "${OUT}/slices-s3b.json"

# M5: two H100 rack GPUs share a uuid
jq '(.items[] | select(.spec.identity.rackGroup=="h100") | .spec.nodes[1].gpus[0].uuid) = ([.items[] | select(.spec.identity.rackGroup=="h100")][0].spec.nodes[0].gpus[0].uuid)' "${OUT}/racks-s3b.json" >"${M}/m5-racks.json"
echo "M5 h100 rack node1 gpu0 uuid: $(probe '.items[] | select(.spec.identity.rackGroup=="h100") | .spec.nodes[1].gpus[0].uuid' "${OUT}/racks-s3b.json") -> $(probe '.items[] | select(.spec.identity.rackGroup=="h100") | .spec.nodes[1].gpus[0].uuid' "${M}/m5-racks.json")"
mutant M5 '^FAIL rack uuids 288, distinct 287' "${OUT}/nodes-s3b.json" "${M}/m5-racks.json" "${OUT}/slices-s3b.json"

echo "== mutant diffs (flattened leaf paths, live '<' vs mutant '>'; want exactly the one field)"
flat() { jq -c 'paths(scalars) as $p | [$p, getpath($p)]' "$1"; }
for p in "m1-nodes:nodes-s3b" "m2-nodes:nodes-s3b" "m3-nodes:nodes-s3b" "m4-racks:racks-s3b" "m5-racks:racks-s3b"; do
  a="${p%%:*}"; b="${p##*:}"
  d="$(diff <(flat "${OUT}/${b}.json") <(flat "${M}/${a}.json") | grep '^[<>]')"
  echo "${a}: $(grep -c . <<<"${d}") changed line(s)"
  cut -c1-220 <<<"${d}" | sed 's/^/    /'
done

echo "DONE fail=${fail} $(date -u +%FT%TZ)"
exit "${fail}"
