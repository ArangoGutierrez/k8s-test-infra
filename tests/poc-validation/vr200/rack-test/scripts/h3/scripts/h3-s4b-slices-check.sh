#!/bin/bash
# H3 step 4b: ResourceSlice checks on fresh dumps, then mutation-verify every
# guard against altered COPIES of the slice dump (the cluster is never
# mutated). Exits non-zero if a live check fails or a mutant survives.
set -uo pipefail
H3="${HOME}/mokka-hetero/h3"
OUT="${HOME}/mokka-hetero/out/h3"
M="${OUT}/mutants"
LOG="${HOME}/mokka-hetero/logs/h3-s4b-slices-check.log"
mkdir -p "${M}"
exec > >(tee "${LOG}") 2>&1
echo "start $(date -u +%FT%TZ)"

kubectl get resourceslices -o json >"${OUT}/slices-s4b.json"
kubectl get nodes -o json >"${OUT}/nodes-s4b.json"
kubectl get sgpuracks.mokka.nvidia.com -o json >"${OUT}/racks-s4b.json"
S="${OUT}/slices-s4b.json"

run_check() {  # slices -> output
  jq -r --slurpfile nodes "${OUT}/nodes-s4b.json" --slurpfile racks "${OUT}/racks-s4b.json" -f "${H3}/check-slices.jq" "$1"
}

echo "== kubectl get resourceslices (count by node prefix)"
kubectl get resourceslices --no-headers | awk '{sub(/-[0-9]+$/, "-NN", $2); print $2, $3}' | sort | uniq -c
echo "== live checks"
live="$(run_check "${S}")"; rc=$?
echo "${live}"
nfail="$(grep -c '^FAIL' <<<"${live}")"; npass="$(grep -c '^PASS' <<<"${live}")"
echo "live: jq rc=${rc} PASS=${npass} FAIL=${nfail} (want 9 PASS, 0 FAIL)"
fail=0
[[ ${rc} -eq 0 && "${nfail}" == "0" && "${npass}" == "9" ]] || fail=1

echo "== independent recount with plain kubectl + jq (no helper)"
kubectl get resourceslices -o json | jq -r '[.items[] | select(.spec.driver=="gpu.nvidia.com") | .spec.devices[]] | "total gpu.nvidia.com devices: \(length)"'
kubectl get resourceslices -o json | jq -r '[.items[] | select(.spec.driver=="gpu.nvidia.com") | .spec.devices[] | "\(.attributes.productName.string)|\(.attributes.architecture.string)|\(.attributes.cudaComputeCapability.version)|\(.capacity.memory.value)"] | group_by(.) | map("\(length) \(.[0])") | .[]'

# ------------------------------------------------------------ mutants
mutant() {  # name slices-file regex... (each regex must match one FAIL line)
  local name="$1" file="$2"; shift 2
  local out f r ok=1; out="$(run_check "${file}")"; f="$(grep '^FAIL' <<<"${out}")"
  for r in "$@"; do grep -qE "${r}" <<<"${f}" || { ok=0; echo "  missing /${r}/"; }; done
  if [[ ${ok} -eq 1 ]]; then echo "KILLED ${name}: ${f//$'\n'/ | }"
  else echo "SURVIVED ${name}: got: ${f:-no FAIL}"; fail=1; fi
}
sel() { printf '.items[] | select(.spec.nodeName=="%s")' "$1"; }

# M1: a second slice for kwok-vr200-03 (same devices, new name)
jq "(.items += [$(sel kwok-vr200-03) | .metadata.name += \"-dup\"])" "${S}" >"${M}/s1.json"
mutant M1 "${M}/s1.json" '^FAIL device totals 340 = 48 real \+ 292 fake$' '^FAIL 4 duplicate \(node, device\) pairs$'
# M2: one VR200 tray device reports Blackwell
jq "($(sel kwok-vr200-10) | .spec.devices[] | select(.name==\"gpu-3\") | .attributes.architecture.string) |= \"Blackwell\"" "${S}" >"${M}/s2.json"
mutant M2 "${M}/s2.json" '^FAIL tuple counts .*"NVIDIA Graphics Device\|Blackwell\|10.7.0":1' '^FAIL fake nodes with a wrong slice count, device count or type: \["kwok-vr200-10"\]$'
# M3: a GB300 device carries a neighbour tray's uuid
u="$(jq -r "$(sel kwok-gb300-05) | .spec.devices[] | select(.name==\"gpu-0\") | .attributes.uuid.string" "${S}")"
jq --arg u "${u}" "($(sel kwok-gb300-04) | .spec.devices[] | select(.name==\"gpu-0\") | .attributes.uuid.string) |= \$u" "${S}" >"${M}/s3.json"
mutant M3 "${M}/s3.json" "^FAIL uuid is not the rack slot's: \[\"kwok-gb300-04/gpu-0\"\]$" '^FAIL fake uuids 288, distinct 287$'
# M4: an H100 node loses one device
jq "($(sel kwok-h100-07) | .spec.devices) |= .[0:7]" "${S}" >"${M}/s4.json"
mutant M4 "${M}/s4.json" '^FAIL device totals 335 = 48 real \+ 287 fake$' '^FAIL fake nodes with a wrong slice count, device count or type: \["kwok-h100-07"\]$'
# M5: a fake slice's pool names another node
jq "($(sel kwok-h100-11) | .spec.pool.name) |= \"kwok-h100-12\"" "${S}" >"${M}/s5.json"
mutant M5 "${M}/s5.json" '^FAIL fake slice metadata: \["kwok-h100-11-gpu.nvidia.com"\]$'
# M6: capacity drift that keeps the identity tuple (only the source-equality guard sees it)
jq "($(sel kwok-gb300-09) | .spec.devices[] | select(.name==\"gpu-2\") | .capacity.memory.value) |= \"287Gi\"" "${S}" >"${M}/s6.json"
mutant M6 "${M}/s6.json" '^FAIL identity differs from the source: \["kwok-gb300-09/gpu-2"\]$'

echo "== mutant diffs (flattened leaf paths, live '<' vs mutant '>')"
flat() { jq -c 'paths(scalars) as $p | [$p, getpath($p)]' "$1"; }
for i in 1 2 3 4 5 6; do
  d="$(diff <(flat "${S}") <(flat "${M}/s${i}.json") | grep '^[<>]')"
  echo "s${i}: $(grep -c . <<<"${d}") changed line(s)"
  head -3 <<<"${d}" | cut -c1-200 | sed 's/^/    /'
done

echo "DONE fail=${fail} $(date -u +%FT%TZ)"
exit "${fail}"
