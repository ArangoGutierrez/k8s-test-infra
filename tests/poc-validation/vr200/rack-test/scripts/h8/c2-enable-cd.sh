#!/bin/bash
# H6 ComputeDomain step 2: turn on the ComputeDomain path of the DRA driver
# already installed on mokka-hetero, in place. No node container restarts
# (so no host-L4 re-leak, H1 3b), no containerd restart, NRI not required.
#
#  a) pick two character-device majors unused by the HOST kernel. This VM runs
#     a real NVIDIA driver, and Mokka keeps a major that the host already
#     assigns to the SAME name (internal/imex/procdevices.go validateMajors:
#     "owner != m.name"), so a default or reused nvidia-caps major could hand a
#     pod a real device node. Same search as docs/guides/compute-domain/run.sh:108-132.
#  b) enable Mokka's IMEX simulator on all three nvml-mock releases: the DRA
#     kubelet-plugin DaemonSet (one per real worker, both containers) reads
#     the substitute proc-devices on EVERY worker, not only the VR200 ones.
#     It stages <root>/imex/proc-devices, driver/dev/nvidia-caps-imex-channels/
#     channel0..2047 (mknod, channel major) and
#     driver/proc/driver/nvidia/capabilities/fabric-imex-mgmt (internal/agent/imex).
#  c) helm upgrade the DRA driver with resources.computeDomains.enabled=true,
#     altProcDevices (chart 0.5.0 values.yaml:33-34, kubeletplugin.yaml:153-154,
#     381-384) and the overlay image from c1. gpuCliqueLabelEnabled stays false
#     (values.yaml:310) so no real node gets nvidia.com/gpu.clique (S3 P2).
set -uo pipefail
LOG="${HOME}/mokka-hetero/logs/h8-c2-enable-cd.log"
mkdir -p "$(dirname "${LOG}")"
exec > >(tee "${LOG}") 2>&1
SRC="${HOME}/mokka-hetero/src"
CHART="${SRC}/deployments/nvml-mock/helm/nvml-mock"
IMG_REPO="dra-driver-nvidia-gpu-imex-nogpu"; IMG_TAG="v0.5.0-mokka"
echo "start $(date -u +%FT%TZ)"
fail=0
# H8: node-container start times (a restart re-leaks the host L4, H1 3b) and
# the real-L4 compute apps, before and after.
node_starts() { for n in $(kind get nodes --name mokka-hetero | sort); do echo "${n} $(docker inspect -f '{{.State.StartedAt}} {{.RestartCount}}' "${n}")"; done; }
node_starts > /tmp/h8-node-starts-before.txt; cat /tmp/h8-node-starts-before.txt
echo "L4 compute apps before:"; nvidia-smi --query-compute-apps=pid --format=csv

echo "== a) host /proc/devices NVIDIA entries (context) and chosen majors"
docker exec mokka-hetero-worker7 grep -iE 'nvidia' /proc/devices
used="$(docker exec mokka-hetero-worker7 awk '$1 ~ /^[0-9]+$/ {print $1}' /proc/devices | sort -nu | tr '\n' ' ')"
pick() { local c; for c in $(seq 240 4095); do case " ${used} " in *" ${c} "*) ;; *) echo "${c}"; return 0;; esac; done; return 1; }
CH_MAJOR="$(pick)"; used="${used} ${CH_MAJOR}"; CAPS_MAJOR="$(pick)"
echo "IMEX channel major=${CH_MAJOR} caps major=${CAPS_MAJOR}"
[[ -n "${CH_MAJOR}" && -n "${CAPS_MAJOR}" ]] || exit 1
echo "${CH_MAJOR} ${CAPS_MAJOR}" > "${HOME}/mokka-hetero/tmp/h8-imex-majors.txt"

echo "== b) Mokka IMEX simulator on the three releases"
for r in h100 gb300 vr200; do
  helm upgrade "nvml-mock-${r}" "${CHART}" -n mokka --reuse-values \
    --set imex.mockChannels.enabled=true \
    --set imex.mockChannels.channelMajor="${CH_MAJOR}" \
    --set imex.mockChannels.capsMajor="${CAPS_MAJOR}" \
    --wait --timeout 300s
  rc=$?; echo "helm upgrade nvml-mock-${r} rc=${rc}"; [[ ${rc} -eq 0 ]] || exit 1
  kubectl -n mokka rollout status "ds/nvml-mock-${r}" --timeout=300s || exit 1
done
for n in $(kubectl get nodes -l nvml-mock/profile -o jsonpath='{.items[*].metadata.name}'); do
  pd="$(docker exec "${n}" grep -E 'nvidia-caps' /var/lib/nvml-mock/imex/proc-devices | tr '\n' ';')"
  ch="$(docker exec "${n}" stat -c '%t %T' /var/lib/nvml-mock/driver/dev/nvidia-caps-imex-channels/channel0 2>&1)"
  cap="$(docker exec "${n}" cat /var/lib/nvml-mock/driver/proc/driver/nvidia/capabilities/fabric-imex-mgmt 2>&1 | head -1)"
  want_ch="$(printf '%x 0' "${CH_MAJOR}")"
  if [[ "${pd}" == *"${CH_MAJOR} nvidia-caps-imex-channels"* && "${pd}" == *"${CAPS_MAJOR} nvidia-caps"* && "${ch}" == "${want_ch}" && "${cap}" == "DeviceFileMinor: 512" ]]; then
    echo "PASS ${n} proc-devices='${pd}' channel0=${ch} ${cap}"
  else
    echo "FAIL ${n} proc-devices='${pd}' channel0=${ch} (want ${want_ch}) cap='${cap}'"; fail=1
  fi
done
(( fail == 0 )) || exit 1

echo "== c) DRA driver: ComputeDomains on"
kubectl get resourceslices -o json | jq -r '[.items[] | select(.spec.driver=="gpu.nvidia.com" and (.spec.nodeName|startswith("mokka-hetero-")))] | map(.spec.devices|length) | add' > /tmp/h8-gpu-devs-before.txt
# Release name as H1 installed it (h1/scripts/s6-dra.sh:9; H3 saw its SA
# nvidia-dra-driver-dra-driver-nvidia-gpu-service-account).
helm upgrade nvidia-dra-driver nvidia/dra-driver-nvidia-gpu --version 0.5.0 -n nvidia --reuse-values \
  --set resources.computeDomains.enabled=true \
  --set altProcDevices=/var/lib/nvml-mock/imex/proc-devices \
  --set image.repository="${IMG_REPO}" --set image.tag="${IMG_TAG}" --set image.pullPolicy=Never \
  --wait --timeout 300s
rc=$?; echo "helm upgrade nvidia-dra-driver rc=${rc}"; [[ ${rc} -eq 0 ]] || exit 1
kubectl -n nvidia rollout status ds/dra-driver-nvidia-gpu-kubelet-plugin --timeout=300s || exit 1
kubectl -n nvidia rollout status deploy/dra-driver-nvidia-gpu-controller --timeout=180s || exit 1
kubectl -n nvidia get pods -o wide

echo "== clique each CD kubelet plugin derived from mock NVML fabric info"
# selector label from the chart render (helm template, chart 0.5.0):
# DaemonSet dra-driver-nvidia-gpu-kubelet-plugin matchLabels {dra-driver-nvidia-gpu-component: kubelet-plugin}
for p in $(kubectl -n nvidia get pods -l dra-driver-nvidia-gpu-component=kubelet-plugin -o name); do
  node="$(kubectl -n nvidia get "${p}" -o jsonpath='{.spec.nodeName}')"
  prof="$(kubectl get node "${node}" -o jsonpath='{.metadata.labels.nvml-mock/profile}')"
  line="$(kubectl -n nvidia logs "${p}" -c compute-domains | grep -m1 'identified fabric clique UUID/ID')"
  echo "${node} ${prof}: ${line##*: }"
done
echo "(expected from the profiles' fabric blocks, no topology overlay in the plugin: vr200 00000000-0000-0000-0000-000000000001/32766,"
echo " gb300 and h100 00000000-0000-0000-0000-000000000001/0; profiles vr200.yaml:77-80, gb300.yaml:55-58, h100.yaml:45-48)"

echo "== invariants the earlier tiers rely on"
# H8: the gpus container restarts with the new image and republishes its
# slices, so give the counts up to 120s to settle before asserting.
for _ in $(seq 1 24); do
  a="$(kubectl get resourceslices -o json | jq -r '[.items[] | select(.spec.driver=="gpu.nvidia.com" and (.spec.nodeName|startswith("mokka-hetero-")))] | map(.spec.devices|length) | add')"
  c="$(kubectl get resourceslices -o json | jq -r '[.items[] | select(.spec.driver=="compute-domain.nvidia.com") | .spec.nodeName] | unique | length')"
  echo "settle: gpu devices=${a} cd-slice nodes=${c}"
  [[ "${a}" == "48" && "${c}" == "9" ]] && break; sleep 5
done
[[ "$(kubectl get nodes -l 'nvml-mock/profile,nvidia.com/gpu.clique' -o name | wc -l)" -eq 0 ]] && echo "PASS no real node has nvidia.com/gpu.clique (S3 P2)" || { echo "FAIL a real node got a clique label"; fail=1; }
after="$(kubectl get resourceslices -o json | jq -r '[.items[] | select(.spec.driver=="gpu.nvidia.com" and (.spec.nodeName|startswith("mokka-hetero-")))] | map(.spec.devices|length) | add')"
[[ "${after}" == "$(cat /tmp/h8-gpu-devs-before.txt)" && "${after}" == "48" ]] && echo "PASS real-tier GPU devices still 48" || { echo "FAIL GPU devices before=$(cat /tmp/h8-gpu-devs-before.txt) after=${after}"; fail=1; }
cd_nodes="$(kubectl get resourceslices -o json | jq -r '[.items[] | select(.spec.driver=="compute-domain.nvidia.com") | .spec.nodeName] | unique | length')"
[[ "${cd_nodes}" -eq 9 ]] && echo "PASS compute-domain.nvidia.com slices on 9 real workers" || { echo "FAIL compute-domain slices on ${cd_nodes} nodes"; fail=1; }
for n in $(kind get nodes --name mokka-hetero); do
  c="$(docker exec "${n}" sh -c 'ls -d /dev/nvidia* 2>/dev/null | wc -l')"; [[ "${c}" -eq 0 ]] || { echo "FAIL ${n} leaked host GPU nodes: ${c}"; fail=1; }
done
node_starts > /tmp/h8-node-starts-after.txt
if cmp -s /tmp/h8-node-starts-before.txt /tmp/h8-node-starts-after.txt; then echo "PASS no kind node container restarted"; else echo "FAIL node container start times changed: run ~/mokka-hetero/scripts/s3b-hide-host-gpu.sh --restart"; diff /tmp/h8-node-starts-before.txt /tmp/h8-node-starts-after.txt; fail=1; fi
echo "L4 compute apps after:"; nvidia-smi --query-compute-apps=pid --format=csv
[[ "$(nvidia-smi --query-compute-apps=pid --format=csv,noheader | wc -l)" -eq 0 ]] && echo "PASS real L4 has no compute apps" || { echo "FAIL real L4 has compute apps"; fail=1; }
echo "DONE fail=${fail} $(date -u +%FT%TZ)"
exit "${fail}"
