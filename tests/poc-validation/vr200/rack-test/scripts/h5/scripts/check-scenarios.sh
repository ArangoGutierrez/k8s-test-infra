#!/bin/bash
# H5 scheduling-correctness checker for the mokka-hetero cluster.
#
# Runs S1 (type targeting), S1b (naive selector, reported only), S2 (no spill)
# and S3 (rack locality) one at a time in namespace sched-test, cleaning up
# between them. Each scenario dumps the API state (pods, all ResourceClaims,
# ResourceSlices, Nodes, SGPURacks, sched-test events) and runs a jq assertion
# program over the dump; every assertion prints PASS or FAIL. Exits 1 on any
# FAIL, including a failed precondition, a cleanup that does not finish, or an
# assertion program that errors or prints the wrong number of check lines.
#
# Env:
#   H5_MANIFESTS  manifest dir (default ~/mokka-hetero/h5/manifests); mutants point elsewhere
#   H5_ONLY       scenarios to run, in order (default "s1 s1b s2 s3")
#   H5_RUN        run id (default UTC timestamp); dumps go to ~/mokka-hetero/out/h5/<run>/
set -uo pipefail
H5="${HOME}/mokka-hetero/h5"
MAN="${H5_MANIFESTS:-${H5}/manifests}"
ONLY="${H5_ONLY:-s1 s1b s2 s3}"
RUN="${H5_RUN:-$(date -u +%Y%m%dT%H%M%SZ)}"
OUT="${HOME}/mokka-hetero/out/h5/${RUN}"
LOG="${HOME}/mokka-hetero/logs/h5-check-${RUN}.log"
NS=sched-test
# Fixed expectations (SPEC topology).
N_S1=4; N_S1B=24; N_FILL=84; N_RUBIN=84; N_BLACKWELL=84; N_S3=18; N_REAL_RUBIN=12
mkdir -p "${OUT}" "$(dirname "${LOG}")"
exec > >(tee "${LOG}") 2>&1
FAILS=0; PASSES=0

say()  { echo "$(date -u +%H:%M:%SZ) $*"; }
pass() { echo "PASS $*"; PASSES=$((PASSES + 1)); }
fail() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }
now()  { date +%s.%N; }
secs() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.1f", b - a }'; }

# count_pods <selector> <bound|running>
count_pods() {
  kubectl -n "${NS}" get pods -l "$1" -o json \
    | jq --arg m "$2" '[.items[] | select(.spec.nodeName != null and ($m == "bound" or .status.phase == "Running"))] | length'
}

# wait_pods <label> <selector> <want> <bound|running> <timeout-s> <t0>; sets GOT
wait_pods() {
  local label="$1" sel="$2" want="$3" mode="$4" to="$5" t0="$6" start
  start="$(date +%s)"
  while :; do
    GOT="$(count_pods "${sel}" "${mode}")"
    [[ "${GOT}" -ge "${want}" ]] && { say "TIME ${label}: ${GOT}/${want} ${mode} after $(secs "${t0}" "$(now)")s (since apply)"; return 0; }
    (( $(date +%s) - start >= to )) && { say "TIME ${label}: TIMEOUT ${to}s with ${GOT}/${want} ${mode}"; return 1; }
    sleep 1
  done
}

# wait_event <label> <selector> <timeout-s>: until a FailedScheduling event names a pod of the selector
wait_event() {
  local label="$1" sel="$2" to="$3" start uids n
  start="$(date +%s)"
  while :; do
    uids="$(kubectl -n "${NS}" get pods -l "${sel}" -o json | jq -c '[.items[].metadata.uid]')"
    n="$(kubectl -n "${NS}" get events -o json | jq --argjson u "${uids}" '[.items[] | select(.reason == "FailedScheduling" and (.involvedObject.uid as $x | any($u[]; . == $x)))] | length')"
    [[ "${n}" -ge 1 ]] && { say "EVENTWAIT ${label}: ${n} FailedScheduling event(s) after $(( $(date +%s) - start ))s"; return 0; }
    (( $(date +%s) - start >= to )) && { say "EVENTWAIT ${label}: none after ${to}s"; return 1; }
    sleep 2
  done
}

dump() { # <name>: one JSON object with everything the assertions read
  local d="${OUT}/$1"
  mkdir -p "${d}"
  kubectl -n "${NS}" get pods -o json > "${d}/pods.json"
  kubectl get resourceclaims -A -o json > "${d}/claims.json"
  kubectl get resourceslices -o json > "${d}/slices.json"
  kubectl get nodes -o json > "${d}/nodes.json"
  kubectl get sgpuracks -o json > "${d}/racks.json"
  kubectl -n "${NS}" get events -o json > "${d}/events.json"
  jq -n --slurpfile p "${d}/pods.json" --slurpfile c "${d}/claims.json" --slurpfile s "${d}/slices.json" \
        --slurpfile n "${d}/nodes.json" --slurpfile r "${d}/racks.json" --slurpfile e "${d}/events.json" \
    '{pods: $p[0].items, claims: $c[0].items, slices: $s[0].items, nodes: $n[0].items, racks: $r[0].items, events: $e[0].items}' \
    > "${d}/dump.json"
}

# assert <name> <program> <expected check lines> [jq args...]
assert() {
  local name="$1" prog="$2" want="$3" rc n f
  shift 3
  jq -r -L "${H5}" "$@" -f "${H5}/${prog}" "${OUT}/${name}/dump.json" > "${OUT}/${name}/assert.txt"
  rc=$?
  cat "${OUT}/${name}/assert.txt"
  n="$(grep -cE '^(PASS|FAIL) ' "${OUT}/${name}/assert.txt")"
  f="$(grep -c '^FAIL ' "${OUT}/${name}/assert.txt")"
  PASSES=$((PASSES + n - f)); FAILS=$((FAILS + f))
  [[ ${rc} -eq 0 ]] || fail "${name}: assertion program exited ${rc}"
  [[ "${n}" == "${want}" ]] || fail "${name}: assertion program printed ${n} check lines, want ${want}"
}

precondition() { # <scenario>: sched-test empty, no ResourceClaim anywhere in the cluster
  local p c
  p="$(kubectl -n "${NS}" get pods --no-headers 2>/dev/null | wc -l)"
  c="$(kubectl get resourceclaims -A --no-headers 2>/dev/null | wc -l)"
  if [[ "${p}" == "0" && "${c}" == "0" ]]; then pass "$1 precondition: sched-test has 0 pods, cluster has 0 ResourceClaims"
  else fail "$1 precondition: sched-test pods=${p}, cluster ResourceClaims=${c}"; fi
}

cleanup() { # <scenario>
  local t0 p c start
  t0="$(now)"; start="$(date +%s)"
  kubectl -n "${NS}" delete deploy,job,pod --all --wait=false > /dev/null
  while :; do
    p="$(kubectl -n "${NS}" get pods --no-headers 2>/dev/null | wc -l)"
    c="$(kubectl -n "${NS}" get resourceclaims --no-headers 2>/dev/null | wc -l)"
    [[ "${p}" == "0" && "${c}" == "0" ]] && break
    (( $(date +%s) - start >= 300 )) && break
    sleep 2
  done
  if [[ "${p}" == "0" && "${c}" == "0" ]]; then pass "$1 cleanup: 0 pods and 0 claims in sched-test after $(secs "${t0}" "$(now)")s"
  else fail "$1 cleanup: pods=${p} claims=${c} after 300s"; fi
}

say "start run=${RUN} manifests=${MAN} only=[${ONLY}] context=$(kubectl config current-context)"
( cd "${MAN}" && sha256sum ./*.yaml )
kubectl apply -f "${MAN}/00-templates.yaml" > /dev/null || fail "apply templates"

for s in ${ONLY}; do
  T0="$(now)"
  say "===== ${s}"
  case "${s}" in
  s1)
    precondition S1
    kubectl apply -f "${MAN}/s1.yaml"
    wait_pods "S1 bound" "mokka-hetero.nvidia.com/scenario=s1" $((3 * N_S1)) bound 120 "${T0}"
    wait_pods "S1 running" "mokka-hetero.nvidia.com/scenario=s1" $((3 * N_S1)) running 120 "${T0}"
    dump s1
    assert s1 assert-s1.jq 16 --argjson n "${N_S1}"
    cleanup S1 ;;
  s1b)
    precondition S1b
    kubectl apply -f "${MAN}/s1b.yaml"
    wait_pods "S1b bound" "mokka-hetero.nvidia.com/scenario=s1b" "${N_S1B}" bound 120 "${T0}"
    wait_pods "S1b running" "mokka-hetero.nvidia.com/scenario=s1b" "${N_S1B}" running 120 "${T0}"
    dump s1b
    assert s1b report-s1b.jq 0
    cleanup S1b ;;
  s2)
    precondition S2
    kubectl apply -f "${MAN}/s2-fill.yaml"
    wait_pods "S2 fill bound" "mokka-hetero.nvidia.com/scenario=s2-fill" "${N_FILL}" bound 300 "${T0}"
    wait_pods "S2 fill running" "mokka-hetero.nvidia.com/scenario=s2-fill" "${N_FILL}" running 300 "${T0}"
    T1="$(now)"
    kubectl apply -f "${MAN}/s2-extra.yaml"
    # Either the scheduler gives up on it (event), or it binds (a spill).
    wait_event "S2 extra" "mokka-hetero.nvidia.com/scenario=s2-extra" 90 \
      || wait_pods "S2 extra bound" "mokka-hetero.nvidia.com/scenario=s2-extra" 1 bound 5 "${T1}"
    sleep 20   # hold: a retry must not bind it either
    say "S2 extra observed for $(secs "${T1}" "$(now)")s"
    dump s2
    assert s2 assert-s2.jq 8 --argjson fill "${N_FILL}" --argjson rubin "${N_RUBIN}" --argjson blackwell "${N_BLACKWELL}"
    cleanup S2 ;;
  s3)
    precondition S3
    kubectl apply -f "${MAN}/s3-a.yaml"
    wait_pods "S3 A bound" "mokka-hetero.nvidia.com/s3-job=a" "${N_S3}" bound 180 "${T0}"
    wait_pods "S3 A running" "mokka-hetero.nvidia.com/s3-job=a" "${N_S3}" running 180 "${T0}"
    T1="$(now)"
    kubectl apply -f "${MAN}/s3-b.yaml"
    wait_event "S3 B" "mokka-hetero.nvidia.com/s3-job=b" 90
    sleep 20   # hold: retries must not bind B either
    say "S3 B observed for $(secs "${T1}" "$(now)")s"
    dump s3
    assert s3 assert-s3.jq 10 --argjson n "${N_S3}" --argjson realrubin "${N_REAL_RUBIN}"
    cleanup S3 ;;
  *) fail "unknown scenario ${s}" ;;
  esac
  say "TIME ${s} total (apply to cleaned up): $(secs "${T0}" "$(now)")s"
done

say "SUMMARY run=${RUN} pass=${PASSES} fail=${FAILS} dumps=${OUT} log=${LOG}"
[[ ${FAILS} -eq 0 ]]
