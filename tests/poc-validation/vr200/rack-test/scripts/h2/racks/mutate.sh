#!/bin/bash
# Mutation-check the rack-draft probe: each mutant must turn the probe red.
set -u
W="${MOKKA_SRC:?set MOKKA_SRC to a checkout of main plus PR 872}"
R=/tmp/mokka-hetero-58fc971e/h2/racks
F="${R}/sgpu-rack-profiles.yaml"
cp "${F}" "${R}/profiles.bak"
run_probe() {
  (cd "${W}" && go test -modfile="${R}/probe.go.mod" -mod=mod -overlay "${R}/overlay.json" -count=1 -run 'TestH2RackDrafts' ./internal/controlplane/api/v1alpha1/ > "${R}/mutant.out" 2>&1)
  echo $?
}
# M1: uppercase hex in a PCI address (CRD pattern ^[0-9a-f]{4}:...).
python3 - "${F}" <<'PY'
import sys; p=sys.argv[1]; s=open(p).read(); n=s.replace('pciAddress: "0002:c1:00.0"','pciAddress: "0002:C1:00.0"',1); assert n!=s; open(p,'w').write(n)
PY
diff "${R}/profiles.bak" "${F}" | grep '^[<>]'
echo "M1 rc=$(run_probe)"; grep -o 'spec.node.topology.gpuSlots\[1\].pciAddress[^"]*"[^"]*"[^,]*' "${R}/mutant.out" | head -1
cp "${R}/profiles.bak" "${F}"
# M2: drop vr200 gpuSlots index 3 (CEL: one slot per GPU).
python3 - "${F}" <<'PY'
import sys; p=sys.argv[1]; s=open(p).read()
blk='''        - index: 3
          pciAddress: "000a:e1:00.0"
          rootComplex: pci000a:80
          numaNode: 1
          hostProcessorIndex: 1
'''
assert s.count(blk)==1; open(p,'w').write(s.replace(blk,'',1))
PY
diff "${R}/profiles.bak" "${F}" | grep -c '^<'
echo "M2 rc=$(run_probe)"; grep -o 'topology.gpuSlots must contain one slot per GPU[^"]*' "${R}/mutant.out" | head -1
cp "${R}/profiles.bak" "${F}"
cmp "${R}/profiles.bak" "${F}" && echo "restored identical"
echo "baseline rc=$(run_probe)"
git -C "${W}" status --short | wc -l
