#!/bin/bash
# Live mutation check for check-scenarios.sh: one deliberate manifest mutant
# per scenario, run through the UNCHANGED checker against the cluster. Each
# mutant must make the checker exit non-zero with its named FAIL line. The
# mutant manifests are copies; the real manifests are never edited.
#   MS1 s1.yaml:       the vr200 workload uses the gb300-x1 template (swap the VR200 selector for GB300's)
#   MS2 s2-*.yaml:     fill and extra use vr200-naive-cc10 (a VR200 selector that also admits GB300)
#   MS3 s3-{a,b}.yaml: podAffinity required -> preferred (weight 100), same term
set -uo pipefail
H5="${HOME}/mokka-hetero/h5"
MUT="${H5}/mutants"
LOG="${HOME}/mokka-hetero/logs/h5-mutate-live.log"
exec > >(tee "${LOG}") 2>&1
survived=0
echo "start $(date -u +%FT%TZ)"
rm -rf "${MUT}"; mkdir -p "${MUT}"
for m in ms1 ms2 ms3; do cp -r "${H5}/manifests" "${MUT}/${m}"; done

sed -i 's/resourceClaimTemplateName: vr200-x1$/resourceClaimTemplateName: gb300-x1/' "${MUT}/ms1/s1.yaml"
sed -i 's/resourceClaimTemplateName: vr200-x1$/resourceClaimTemplateName: vr200-naive-cc10/' "${MUT}/ms2/s2-fill.yaml" "${MUT}/ms2/s2-extra.yaml"
python3 - "${MUT}/ms3/s3-a.yaml" "${MUT}/ms3/s3-b.yaml" <<'PY'
import sys
for path in sys.argv[1:]:
    job = "a" if path.endswith("s3-a.yaml") else "b"
    src = open(path).read()
    old = ("          requiredDuringSchedulingIgnoredDuringExecution:\n"
           "          - labelSelector:\n"
           "              matchLabels:\n"
           f"                mokka-hetero.nvidia.com/s3-job: {job}\n"
           "            topologyKey: nvidia.com/gpu.clique\n")
    new = ("          preferredDuringSchedulingIgnoredDuringExecution:\n"
           "          - weight: 100\n"
           "            podAffinityTerm:\n"
           "              labelSelector:\n"
           "                matchLabels:\n"
           f"                  mokka-hetero.nvidia.com/s3-job: {job}\n"
           "              topologyKey: nvidia.com/gpu.clique\n")
    n = src.count(old)
    if n != 1:
        sys.exit(f"{path}: block found {n} times, want 1")
    open(path, "w").write(src.replace(old, new))
PY
[[ $? -eq 0 ]] || { echo "ABORT: ms3 substitution failed"; exit 2; }

# Every mutant must differ from the real manifests in exactly the intended files.
for m in ms1 ms2 ms3; do
  echo "== ${m}: diff -u manifests mutants/${m}"
  diff -ru "${H5}/manifests" "${MUT}/${m}"
  echo "   changed files: $(diff -rq "${H5}/manifests" "${MUT}/${m}" | wc -l)"
done

run() { # <mutant> <scenario> <target FAIL substring>
  local m="$1" s="$2" target="$3" rc
  echo "== RUN ${m} (H5_ONLY=${s})"
  H5_MANIFESTS="${MUT}/${m}" H5_ONLY="${s}" H5_RUN="mut-${m}" bash "${H5}/check-scenarios.sh" > "${MUT}/${m}.out" 2>&1
  rc=$?
  grep -E '^(PASS|FAIL|EVENT|INFO|REPORT|TIMING)|TIME |SUMMARY' "${MUT}/${m}.out" | cut -c1-600
  if [[ ${rc} -ne 0 ]] && grep -qF "FAIL ${target}" "${MUT}/${m}.out"; then
    echo "KILLED ${m}: checker rc=${rc}, target line present: FAIL ${target}"
  else
    echo "SURVIVED ${m}: checker rc=${rc}, target line present: $(grep -cF "FAIL ${target}" "${MUT}/${m}.out")"
    survived=$((survived + 1))
  fi
}
run ms1 s1 "S1 vr200: every allocated device is Rubin"
run ms2 s2 "S2: zero non-Rubin (so zero Blackwell) devices allocated"
run ms3 s3 "S3 B: 18 pods, none bound, all Pending"
echo "after mutants: sched-test pods=$(kubectl -n sched-test get pods --no-headers 2>/dev/null | wc -l) cluster claims=$(kubectl get resourceclaims -A --no-headers 2>/dev/null | wc -l)"
echo "DONE survived=${survived} $(date -u +%FT%TZ)"
exit "${survived}"
