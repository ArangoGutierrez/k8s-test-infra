#!/bin/bash
# Polls the VM host's real L4 once a second while an H4 detection Job runs.
# If any compute process appears, it deletes the Job and its pod at once and
# writes out/<job>.L4-ALERT. Exits when out/<job>.watch-stop exists.
set -u
JOB=$1
CTX=kind-mokka-hetero
NS=detect-vllm
D=~/mokka-hetero/h4/out
LOG=${D}/${JOB}.watchdog.log
n=0
fails=0
echo "start $(date -u +%FT%TZ) pid=$$" >> "${LOG}"
while [ ! -f "${D}/${JOB}.watch-stop" ]; do
  apps=$(nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader 2>&1)
  rc=$?
  n=$((n + 1))
  if [ "${rc}" -ne 0 ]; then
    fails=$((fails + 1))
    echo "$(date -u +%FT%TZ) poll=${n} NVSMI_FAIL rc=${rc} ${apps}" >> "${LOG}"
  elif [ -n "${apps}" ]; then
    echo "$(date -u +%FT%TZ) poll=${n} L4 PROCESS: ${apps}" | tee -a "${LOG}" > "${D}/${JOB}.L4-ALERT"
    nvidia-smi >> "${D}/${JOB}.L4-ALERT" 2>&1
    kubectl --context "${CTX}" -n "${NS}" delete job "${JOB}" --wait=false >> "${LOG}" 2>&1
    kubectl --context "${CTX}" -n "${NS}" delete pod -l "job-name=${JOB}" --grace-period=0 --force >> "${LOG}" 2>&1
    echo "$(date -u +%FT%TZ) job and pod deleted" >> "${LOG}"
  fi
  if [ $((n % 15)) -eq 0 ]; then
    echo "$(date -u +%FT%TZ) poll=${n} ok apps=[${apps}] $(nvidia-smi --query-gpu=memory.used,utilization.gpu --format=csv,noheader 2>&1)" >> "${LOG}"
  fi
  sleep 1
done
echo "stop $(date -u +%FT%TZ) polls=${n} nvsmi_fails=${fails} alert=$([ -f "${D}/${JOB}.L4-ALERT" ] && echo YES || echo no)" >> "${LOG}"
