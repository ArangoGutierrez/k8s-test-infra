#!/bin/bash
# D1 fixed-expectation identity check. Exits 1 unless (a) the cluster's
# gpu.nvidia.com devices carry exactly the identity tuples
# productName|architecture|cudaComputeCapability Hopper 168 / Blackwell 84 /
# Rubin 84 and no other, and (b) every real worker's slice carries the tuple of
# its FIXED type (worker..worker3 h100 x8, worker4-6 gb300 x4, worker7-9 vr200
# x4). The expectations are constants here; nothing is read from node labels.
set -uo pipefail
fail=0
s="$(kubectl get resourceslices -o json)" || { echo "FAIL kubectl get resourceslices"; exit 1; }
tuples='.spec.devices[] | "\(.attributes.productName.string)|\(.attributes.architecture.string)|\(.attributes.cudaComputeCapability.version)"'

echo "== identity tuples over all gpu.nvidia.com devices (count tuple)"
got="$(jq -r "[.items[] | select(.spec.driver == \"gpu.nvidia.com\") | ${tuples}] | group_by(.) | map(\"\(length) \(.[0])\") | .[]" <<<"${s}")"
echo "${got}"
want=$'84 NVIDIA GB300 NVL|Blackwell|10.0.0\n84 NVIDIA Graphics Device|Rubin|10.7.0\n168 NVIDIA H100 80GB HBM3|Hopper|9.0.0'
if [[ "${got}" == "${want}" ]]; then echo "PASS identity counts are exactly Hopper 168 / Blackwell 84 / Rubin 84"
else echo "FAIL identity counts differ from Hopper 168 / Blackwell 84 / Rubin 84"; fail=1; fi

echo "== real workers against their fixed type"
declare -A T=([mokka-hetero-worker]=h100 [mokka-hetero-worker2]=h100 [mokka-hetero-worker3]=h100
              [mokka-hetero-worker4]=gb300 [mokka-hetero-worker5]=gb300 [mokka-hetero-worker6]=gb300
              [mokka-hetero-worker7]=vr200 [mokka-hetero-worker8]=vr200 [mokka-hetero-worker9]=vr200)
declare -A W=([h100]="8 NVIDIA H100 80GB HBM3|Hopper|9.0.0"
              [gb300]="4 NVIDIA GB300 NVL|Blackwell|10.0.0"
              [vr200]="4 NVIDIA Graphics Device|Rubin|10.7.0")
for n in $(printf '%s\n' "${!T[@]}" | sort); do
  g="$(jq -r --arg n "${n}" "[.items[] | select(.spec.driver == \"gpu.nvidia.com\" and .spec.nodeName == \$n) | ${tuples}] | group_by(.) | map(\"\(length) \(.[0])\") | join(\" + \")" <<<"${s}")"
  w="${W[${T[${n}]}]}"
  if [[ "${g}" == "${w}" ]]; then echo "PASS ${n} fixed=${T[${n}]}: ${g}"
  else echo "FAIL ${n} fixed=${T[${n}]}: got [${g}] want [${w}]"; fail=1; fi
done
echo "IDENTITY fail=${fail}"
exit "${fail}"
