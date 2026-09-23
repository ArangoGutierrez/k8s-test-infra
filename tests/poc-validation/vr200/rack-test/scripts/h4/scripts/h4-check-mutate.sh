#!/bin/bash
# Mutation checks for h4-check.py: each mutant changes ONE input and the gate
# must go red (rc=1) naming the changed field; the unmutated baseline must be green.
set -u
H4=/tmp/mokka-hetero-58fc971e/h4
M=${H4}/out/mut
run() {  # $1 label
  python3 "${H4}/scripts/h4-check.py" "${M}" "${H4}/out/live-slices.json" > "${M}.log" 2>&1
  rc=$?
  echo "== ${1}: rc=${rc} $(grep -c '^FAIL' "${M}.log") FAIL line(s)"
  grep '^FAIL' "${M}.log"
}
fresh() {
  rm -rf "${M}"; mkdir -p "${M}"
  for t in h100 gb300; do cp -R "${H4}/out/${t}" "${M}/${t}"; done
  cp -R "${H4}/out/vr200-run2" "${M}/vr200"
}
fresh; run "baseline"
fresh; sed -i '' 's/^RESULT compute_capability_0=10.7$/RESULT compute_capability_0=10.0/' "${M}/vr200/pod.log"
diff "${H4}/out/vr200-run2/pod.log" "${M}/vr200/pod.log"; run "M1 vr200 vLLM reports CC 10.0"
fresh; sed -i '' 's/^\(IDENTITY gpu0 name=NVIDIA Graphics Device\) arch=13 /\1 arch=10 /' "${M}/vr200/pod.log"
diff "${H4}/out/vr200-run2/pod.log" "${M}/vr200/pod.log"; run "M2 vr200 NVML (phase B) reports Blackwell enum 10"
fresh; sed -i '' 's/device: gpu-0$/device: gpu-3/' "${M}/vr200/claims.yaml"
diff "${H4}/out/vr200-run2/claims.yaml" "${M}/vr200/claims.yaml"; run "M3 claim names a different device than the pod saw"
fresh; printf '2026-09-23T12:49:00Z poll=5 L4 PROCESS: 999, python3, 300 MiB\n' >> "${M}/gb300/watchdog.log"
diff "${H4}/out/gb300/watchdog.log" "${M}/gb300/watchdog.log"; run "M4 watchdog saw an L4 process"
fresh; echo "[Wed Sep 23 12:47:00 2026] NVRM: API mismatch: the client has the version 580.95.05" > "${M}/h100/dmesg-nvrm.txt"
run "M5 NVRM kernel line appeared"
rm -rf "${M}" "${M}.log"
