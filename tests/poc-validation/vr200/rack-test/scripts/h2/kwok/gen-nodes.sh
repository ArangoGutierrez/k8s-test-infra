#!/bin/bash
# Emit the 54 KWOK Node objects of the mokka-hetero KWOK tier on stdout:
# 18 VR200 trays, 18 GB300 trays, 18 H100 HGX nodes.
#
# Usage: ./gen-nodes.sh > nodes.yaml && kubectl apply -f nodes.yaml
#
# What each field is for (citations are to the pinned sources):
# - annotation kwok.x-k8s.io/node=fake: the only selector the in-cluster
#   kwok-controller manages (kwok-v0.8.0.yaml:2424,
#   manageNodesWithAnnotationSelector: 'kwok.x-k8s.io/node=fake').
# - taint kwok.x-k8s.io/node=fake:NoSchedule: keeps off every workload that
#   does not tolerate it, including the DRA kubelet plugin (chart 0.5.0
#   values.yaml:290-293 tolerates only nvidia.com/gpu) and the Mokka
#   control-plane Deployment (nvml-mock values.yaml:403, tolerations: []).
#   It does NOT keep nvml-mock off: that DaemonSet tolerates every taint
#   (nvml-mock values.yaml:67-68; docs/guides/device-plugin.md:176-182). The
#   nvml-mock releases are kept off by their nodeSelector
#   nvml-mock/profile=<p>, so these Nodes must never carry nvml-mock/profile.
#   They also carry none of the labels the DRA kubelet plugin's node affinity
#   accepts (chart values.yaml:319-352: NFD pci-10de/0302/0300, cpu vendor,
#   nvidia.com/gpu.present) nor mokka.nvidia.com/type=sgpu.
# - mokka.nvidia.com/sgpu-node=true + mokka.nvidia.com/pool=<pool>: Mokka
#   control-plane eligibility (internal/sgpu/inventory/allocate/selectors.go:19,
#   123) and the rack-group selector key (examples/mokka-controller).
# - status: capacity/allocatable is a scheduling envelope, not GPU identity:
#   GPU identity lives only in the cloned ResourceSlices. Scenario pods request
#   no cpu/memory. The node-initialize stage keeps these values
#   (stage-fast-v0.8.0.yaml:107-122) and fills conditions/addresses.
#   kubernetes.io/arch is amd64 to match the real kind tier they are cloned
#   from; it is not part of GPU identity.
set -euo pipefail

emit_node() {
  local name="$1" gpu_type="$2" pool="$3"
  cat <<EOF
---
apiVersion: v1
kind: Node
metadata:
  name: ${name}
  annotations:
    node.alpha.kubernetes.io/ttl: "0"
    kwok.x-k8s.io/node: fake
  labels:
    kubernetes.io/hostname: ${name}
    kubernetes.io/os: linux
    kubernetes.io/arch: amd64
    type: kwok
    mokka-hetero.nvidia.com/tier: kwok
    mokka-hetero.nvidia.com/gpu-type: ${gpu_type}
    mokka.nvidia.com/sgpu-node: "true"
    mokka.nvidia.com/pool: ${pool}
spec:
  taints:
  - key: kwok.x-k8s.io/node
    value: fake
    effect: NoSchedule
status:
  allocatable:
    cpu: "64"
    memory: 512Gi
    pods: "110"
  capacity:
    cpu: "64"
    memory: 512Gi
    pods: "110"
  nodeInfo:
    architecture: amd64
    bootID: ""
    containerRuntimeVersion: ""
    kernelVersion: ""
    kubeProxyVersion: fake
    kubeletVersion: fake
    machineID: ""
    operatingSystem: linux
    osImage: ""
    systemUUID: ""
  phase: Running
EOF
}

for gpu_type in vr200 gb300 h100; do
  for i in $(seq -w 0 17); do
    emit_node "kwok-${gpu_type}-${i}" "${gpu_type}" "kwok-${gpu_type}"
  done
done
