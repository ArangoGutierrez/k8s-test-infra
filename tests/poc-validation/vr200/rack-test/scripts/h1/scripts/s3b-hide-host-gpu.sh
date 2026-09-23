#!/bin/bash
# The VM's real L4 (/dev/nvidia0 195:0, nvidiactl, uvm, caps) leaks into every
# privileged kind node container and from there into privileged pods. The mock
# engine's detectVisibleDevices then sees /dev/nvidia0 present and nvidia1..N
# absent, and exposes ONE GPU per node. Removing the leaked nodes from each kind
# node's private /dev tmpfs restores the "none present -> no filtering" path and
# keeps the real GPU out of the cluster. Idempotent; must be re-run if a kind
# node container restarts (Docker repopulates /dev). Pods started before the
# removal keep their own copies, so the DaemonSets are restarted afterwards.
set -uo pipefail
CTX=kind-mokka-hetero
for n in $(kind get nodes --name mokka-hetero | sort); do
  docker exec "${n}" sh -c 'rm -rf /dev/nvidia0 /dev/nvidia1 /dev/nvidia2 /dev/nvidia3 /dev/nvidia4 /dev/nvidia5 /dev/nvidia6 /dev/nvidia7 /dev/nvidiactl /dev/nvidia-modeset /dev/nvidia-uvm /dev/nvidia-uvm-tools /dev/nvidia-caps /dev/nvidia-caps-imex-channels'
  left=$(docker exec "${n}" sh -c 'ls -d /dev/nvidia* 2>/dev/null | wc -l')
  echo "${n} remaining /dev/nvidia* entries: ${left}"
done
if [ "${1:-}" = "--restart" ]; then
  for ds in nvml-mock-h100 nvml-mock-gb300 nvml-mock-vr200; do
    kubectl --context "${CTX}" -n mokka rollout restart ds "${ds}"
  done
  for ds in nvml-mock-h100 nvml-mock-gb300 nvml-mock-vr200; do
    kubectl --context "${CTX}" -n mokka rollout status ds "${ds}" --timeout=300s
  done
  kubectl --context "${CTX}" -n nvidia rollout restart ds dra-driver-nvidia-gpu-kubelet-plugin
  kubectl --context "${CTX}" -n nvidia rollout status ds dra-driver-nvidia-gpu-kubelet-plugin --timeout=300s
fi
echo DONE
