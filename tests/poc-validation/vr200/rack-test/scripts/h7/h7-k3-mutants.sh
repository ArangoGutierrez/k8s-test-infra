#!/bin/bash
# H7 k3 mutants: run k3's OWN verify jq program (extracted from
# h7-k3-shadow-capacity.sh, not re-typed) against the live node dump k3 wrote,
# then against three edited copies of that dump. Each mutant must produce a FAIL.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
LOG="${HOME}/mokka-hetero/logs/h7-k3-mutants.log"
exec > >(tee "${LOG}") 2>&1
prog="$(awk '
  /jq -r --rawfile counts/ {f=1; sub(/.*--rawfile counts [^ ]+ \x27/, ""); print; next}
  f && /\x27 \/tmp\/h7-nodes-after.json/ {sub(/\x27 \/tmp\/h7-nodes-after.json.*/, ""); print; exit}
  f {print}' h7-k3-shadow-capacity.sh)"
echo "extracted program: $(printf '%s\n' "${prog}" | wc -l) lines, sha256 $(printf '%s' "${prog}" | sha256sum | cut -c1-16)"
run() { # $1 label, $2 nodes json
  local out
  out="$(jq -r --rawfile counts /tmp/h7-slice-counts.txt "${prog}" "$2")"
  echo "${1}: PASS=$(grep -c '^PASS' <<< "${out}") FAIL=$(grep -c '^FAIL' <<< "${out}")"
  grep '^FAIL' <<< "${out}"
}
R=mokka-hetero.nvidia.com
run "live (as k3 left it)" /tmp/h7-nodes-after.json
jq --arg r "${R}/tas-vr200-gpu" '(.items[] | select(.metadata.name=="kwok-vr200-05") | .status.allocatable[$r]) = "8"' /tmp/h7-nodes-after.json > /tmp/h7-m1.json
run "M1 kwok-vr200-05 declares 8, slice has 4" /tmp/h7-m1.json
jq --arg r "${R}/tas-vr200-gpu" --arg w "${R}/tas-gb300-gpu" '(.items[] | select(.metadata.name=="kwok-vr200-06") | .status.allocatable) |= (del(.[$r]) + {($w): "4"})' /tmp/h7-nodes-after.json > /tmp/h7-m2.json
run "M2 kwok-vr200-06 carries the gb300 key" /tmp/h7-m2.json
jq --arg r "${R}/tas-vr200-gpu" '(.items[] | select(.metadata.name=="mokka-hetero-worker7") | .status.allocatable[$r]) = "4"' /tmp/h7-nodes-after.json > /tmp/h7-m3.json
run "M3 real worker7 carries a tas key" /tmp/h7-m3.json
