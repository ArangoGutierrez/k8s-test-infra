#!/bin/bash
# One H4 detection Job for one GPU type on one real node, with the real-L4
# watchdog running for its whole life. Usage: h4-run.sh <type> <node>
# Exit codes: 0 ran, 2 leaked host GPU nodes, 3 another Job present,
# 4 L4 busy before start, 5 L4 ALERT during the run.
set -uo pipefail
TYPE=$1
NODE=$2
CTX=kind-mokka-hetero
NS=detect-vllm
JOB=h4-vllm-${TYPE}
H4=~/mokka-hetero/h4
OUT=${H4}/out/${TYPE}
mkdir -p "${OUT}"
k() { kubectl --context "${CTX}" "$@"; }
q_apps() { nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader 2>&1; }

echo "start $(date -u +%FT%TZ) type=${TYPE} node=${NODE}"
started=$(docker inspect -f '{{.State.StartedAt}}' "${NODE}")
leaked=$(docker exec "${NODE}" sh -c 'ls -d /dev/nvidia* 2>/dev/null | wc -l')
echo "pre node StartedAt=${started} leaked_dev_nvidia=${leaked}"
[ "${leaked}" = "0" ] || { echo "ABORT leaked host GPU nodes on ${NODE}: run s3b-hide-host-gpu.sh --restart"; exit 2; }
others=$(k -n "${NS}" get jobs --no-headers 2>/dev/null | wc -l)
echo "pre jobs in ${NS}: ${others}"
[ "${others}" = "0" ] || { echo "ABORT another Job exists in ${NS}"; exit 3; }
apps=$(q_apps)
echo "pre host L4 compute apps: [${apps}]"
[ -z "${apps}" ] || { echo "ABORT L4 busy before start"; exit 4; }
nvrm0=$(sudo -n dmesg | grep -c NVRM)
echo "pre dmesg NVRM lines: ${nvrm0}"

rm -f "${H4}/out/${JOB}.watch-stop" "${H4}/out/${JOB}.L4-ALERT" "${H4}/out/${JOB}.watchdog.log"
nohup bash "${H4}/scripts/h4-l4-watchdog.sh" "${JOB}" > /dev/null 2>&1 &
sleep 3
echo "watchdog: $(head -1 "${H4}/out/${JOB}.watchdog.log")"

sed -e "s/__TYPE__/${TYPE}/g" -e "s/__NODE__/${NODE}/g" "${H4}/manifests/job.tmpl.yaml" > "${OUT}/job.yaml"
k apply -f "${OUT}/job.yaml"
echo "apply rc=$? at $(date -u +%FT%TZ)"

phase=""
for _ in $(seq 1 180); do
  phase=$(k -n "${NS}" get pod -l "job-name=${JOB}" -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
  case "${phase}" in Running|Succeeded|Failed) break ;; esac
  sleep 2
done
POD=$(k -n "${NS}" get pod -l "job-name=${JOB}" -o jsonpath='{.items[0].metadata.name}')
echo "pod ${POD} phase=${phase} node=$(k -n "${NS}" get pod "${POD}" -o jsonpath='{.spec.nodeName}') at $(date -u +%FT%TZ)"

echo "== claim allocation (while the pod runs)"
k -n "${NS}" get resourceclaims -o yaml > "${OUT}/claims.yaml"
k -n "${NS}" get resourceclaims -o jsonpath='{range .items[*]}{.metadata.name}{" pool="}{.status.allocation.devices.results[*].pool}{" device="}{.status.allocation.devices.results[*].device}{" driver="}{.status.allocation.devices.results[*].driver}{" reservedFor="}{.status.reservedFor[*].name}{"\n"}{end}'
echo "== node ${NODE} /var/run/cdi (claim specs; the two nvml-mock specs are listed, not printed)"
docker exec "${NODE}" sh -c 'ls -la /var/run/cdi; for f in /var/run/cdi/*; do case "${f}" in */nvidia.yaml|*/nvml-mock-nri.yaml) ;; *) echo "== ${f}"; cat "${f}" ;; esac; done' > "${OUT}/node-cdi.txt" 2>&1
cat "${OUT}/node-cdi.txt"

echo "== waiting for the Job"
result=""
for _ in $(seq 1 260); do
  s=$(k -n "${NS}" get job "${JOB}" -o jsonpath='{.status.succeeded}/{.status.failed}' 2>/dev/null)
  [ -f "${H4}/out/${JOB}.L4-ALERT" ] && { result="L4-ALERT"; break; }
  case "${s}" in 1/*) result=succeeded; break ;; */1) result=failed; break ;; esac
  [ -z "${s}" ] && { result="job-gone"; break; }
  sleep 5
done
echo "job result=${result} at $(date -u +%FT%TZ)"

k -n "${NS}" logs "${POD}" -c stage-nvml > "${OUT}/init.log" 2>&1
k -n "${NS}" logs "${POD}" -c vllm > "${OUT}/pod.log" 2>&1
echo "logs rc=$? lines=$(wc -l < "${OUT}/pod.log")"
k -n "${NS}" get pod "${POD}" -o yaml > "${OUT}/pod.yaml" 2>&1
k -n "${NS}" get events --sort-by=.lastTimestamp > "${OUT}/events.txt" 2>&1

echo "== host L4 after the Job"
echo "compute apps: [$(q_apps)]"
nvidia-smi --query-gpu=name,memory.used,utilization.gpu --format=csv,noheader
echo "dmesg NVRM lines now: $(sudo -n dmesg | grep -c NVRM) (before: ${nvrm0}); new lines:"
sudo -n dmesg -T | grep NVRM | tail -n +$((nvrm0 + 1)) | tee "${OUT}/dmesg-nvrm.txt"

touch "${H4}/out/${JOB}.watch-stop"
sleep 3
cp "${H4}/out/${JOB}.watchdog.log" "${OUT}/watchdog.log"
echo "== watchdog"
head -1 "${OUT}/watchdog.log"; grep -vE ' ok ' "${OUT}/watchdog.log" | tail -n +2; tail -1 "${OUT}/watchdog.log"
[ -f "${H4}/out/${JOB}.L4-ALERT" ] && { echo "L4 ALERT:"; cat "${H4}/out/${JOB}.L4-ALERT"; cp "${H4}/out/${JOB}.L4-ALERT" "${OUT}/"; }

echo "== cleanup"
k -n "${NS}" delete job "${JOB}" --wait=true --timeout=120s
k -n "${NS}" wait --for=delete pod -l "job-name=${JOB}" --timeout=120s 2>&1 | tail -1
sleep 5
echo "claims left in ${NS}: $(k -n "${NS}" get resourceclaims --no-headers 2>/dev/null | wc -l)"
echo "claim CDI specs left on ${NODE}: $(docker exec "${NODE}" sh -c 'ls /var/run/cdi | grep -vcE "^(nvidia|nvml-mock-nri)\.yaml$"')"
echo "DONE result=${result} $(date -u +%FT%TZ)"
[ "${result}" = "L4-ALERT" ] && exit 5
exit 0
