#!/bin/bash
# Discrimination check for h4-l4-watchdog.sh with a PATH-shimmed nvidia-smi
# (no GPU is touched): a shim that reports a compute process must produce an
# ALERT file; a shim that reports none must not.
set -u
T=~/mokka-hetero/h4/test
OUT=~/mokka-hetero/h4/out
mkdir -p "${T}/busy" "${T}/idle"
printf '#!/bin/bash\ncase "$*" in *query-compute-apps*) echo "4242, /fake/proc, 123 MiB" ;; *) echo shim-busy ;; esac\n' > "${T}/busy/nvidia-smi"
printf '#!/bin/bash\ncase "$*" in *query-compute-apps*) : ;; *) echo shim-idle ;; esac\n' > "${T}/idle/nvidia-smi"
chmod +x "${T}/busy/nvidia-smi" "${T}/idle/nvidia-smi"
for mode in busy idle; do
  JOB=h4-selftest-${mode}
  rm -f "${OUT}/${JOB}".*
  ( sleep 4; touch "${OUT}/${JOB}.watch-stop" ) &
  PATH="${T}/${mode}:${PATH}" bash ~/mokka-hetero/h4/scripts/h4-l4-watchdog.sh "${JOB}"
  wait
  echo "== ${mode}: alert file $([ -f "${OUT}/${JOB}.L4-ALERT" ] && echo PRESENT || echo absent)"
  grep -E 'L4 PROCESS|stop ' "${OUT}/${JOB}.watchdog.log" | head -2
  rm -f "${OUT}/${JOB}".*
done
