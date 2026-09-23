# Mokka heterogeneous rack test: VR200 detection and scheduling correctness

Date: 2026-09-23. Session 58fc971e. Everything below was run on a kind cluster
on a remote VM <vm> (x86, 4 CPUs, 15 GB) with no VR200 hardware.
Every result marked "verified" was re-run by the chief; the others carry the
worker's evidence in the task reports in this directory.

## Cluster

- Mokka = upstream main e8e49aeb + PR #872 (vr200 preview profile), local only.
- 64 nodes: 10 real kind nodes (1 control plane; 3 H100 x8, 3 GB300 x4,
  3 VR200 x4) + 54 KWOK nodes (one full VR200 rack of 18 trays, one GB300 rack
  of 18 trays, 18 H100 nodes). 1/3 of each type: 21 nodes per type.
- 336 GPUs published as DRA ResourceSlices (dra-driver-nvidia-gpu 0.5.0):
  168 Hopper, 84 Blackwell, 84 Rubin. KWOK slices cloned from real ones.
- Racks: Mokka control plane (SGPURackProfile / SGPUInventory) stamps one
  `nvidia.com/gpu.clique` value per 18-tray rack.

## Results

| Area | Result | Status |
|---|---|---|
| DRA identity | Exactly 3 identity tuples: H100 "NVIDIA H100 80GB HBM3" Hopper 9.0; GB300 "NVIDIA GB300 NVL" Blackwell 10.0; VR200 "NVIDIA Graphics Device" Rubin 10.7 | verified |
| vLLM v0.30.0 per type (DRA claim + Mokka NVML) | Name, CC, memory, UUID, PCI match the allocated slice device for all 3 types (51/51, 5 mutants red). FP8 and DeepGEMM on for all; NVFP4 and TRT-LLM attention off only on H100. CUDA stops at cuInit 803 (driver mismatch) | worker-verified; key lines re-run |
| Detection mutation | Relabel one VR200 node to GB300: identity check RED (Rubin 80 / Blackwell 88), revert GREEN | worker |
| S1 type targeting | Each type's workload gets only its type's devices on its type's nodes | verified (42/42 run) |
| S1b naive selector | Selecting "VR200" by memory 288Gi or CC major 10 put 2-5 of 12 pods on GB300 | worker |
| S2 no spill | All 84 Rubin claimed; the 85th stays Pending with FailedScheduling while all 84 Blackwell stay free | verified |
| S3 rack locality | 18-pod job (4 GPUs/pod, required affinity on the clique) fills the 18 trays of the VR200 rack; a second one stays Pending instead of splitting or using the 3 clique-less real VR200 nodes | verified |
| Kueue v0.19.5 TAS | 19-pod job refused by topology; 18-pod job one pod per tray in one rack, TAS hostname == bound node == DRA device pool; second job held by TOPOLOGY with quota room (72/144); admitted when the rack frees | verified (10/10 run) |
| ComputeDomain (upstream DRA 0.5.0) on the 3 real VR200 nodes | CD Ready, one clique ...0001.32766; 3 real `nvidia-imex --nogpu` daemons READY, 3 peers READY NO_GPU, pairwise connected; channel0 char device (major 255) in every workload pod; daemon kill -> 2 -> back to 3 | verified (except the kill, worker, 5/5 mutants) |
| Real-GPU safety | The VM's real L4 never ran a compute app | verified |

## Findings

Scheduling policy (relevant to every GPU cloud operator):
1. Selecting VR200 by memory (288 GiB) or compute-capability major 10 also
   matches GB300. Only architecture == Rubin (plus CC 10.7) isolates VR200.
2. The DRA chart maps extended resource `nvidia.com/gpu` to DeviceClass
   `gpu.nvidia.com`, i.e. ANY GPU type (live cluster). A pod asking for
   `nvidia.com/gpu` bypasses per-type selectors.

Kueue:
3. Kueue v0.19.5 (and v0.20.0-rc.1) TAS cannot see DRA devices (capacity =
   node allocatable; docs say DRA+TAS unsupported). Workable today only with a
   per-type accounting resource. That is honest only if every consumer of a
   tray declares it: a DRA pod outside Kueue made Kueue admit an 18-pod job
   whose 18th pod could never run.
4. A TAS pod set with no resource requests is never admitted (upstream bug candidate).

DRA driver 0.5.0 (kubernetes-sigs/dra-driver-nvidia-gpu):
5. ComputeDomain in its default mode (IMEXDaemonsWithDNSNames) requires GPU
   driver >= 570.158.01; older-driver nodes crash-loop the CD plugin (GPU
   allocation still works).
6. The same mode sizes every IMEX domain for 18 nodes, so a healthy 3-node
   domain reports DEGRADED, never UP. "status == UP" health checks misfire on
   partial racks.
7. Slice device order changes on every plugin restart (Go map iteration).
8. The ResourceSlice ValidatingAdmissionPolicy matches a service account name
   the plugin does not run as, so it restricts no one.

Mokka (fixable, worth issues before wider adoption):
9. With the standard DRA path, pods see "Mock NVIDIA A100-SXM4-40GB": the
   Mokka config env never reaches DRA/CDI-injected containers (closed #747
   fixed the device-plugin path only). The scheduler says VR200, the workload
   sees A100.
10. On a host with a real NVIDIA GPU, Mokka's device nodes reuse the real
    majors: pods receive the real L4's /dev/nvidia0, nvidiactl and uvm. Only a
    driver-version mismatch kept CUDA off the physical GPU. Privileged kind
    nodes also inherit the host GPU at start.
11. GPU UUIDs and PCI IDs repeat across all nodes of a type (from the profile).
12. h100 and gb300 profiles share one NVLink fabric identity; their driver
    versions are below the ComputeDomain minimum.
13. Mock libcuda has no SONAME and lacks symbols vLLM links, so it breaks
    `import vllm` when on the library path; the device-plugin guide path
    injects no driver into pods.
14. The rack controller's clique (KWOK racks) and the NVML fabric clique on
    real nodes are unrelated; "a ComputeDomain inside the VR200 rack" cannot be
    expressed today.
15. Docs drift: `dra.k8s.io/pcieRoot` (driver publishes
    `resource.kubernetes.io/pcieRoot`); values.yaml says altProcDevices is in no
    release (chart 0.5.0 ships it).

## Left in place on the VM

Cluster `mokka-hetero` (64 nodes): Kueue 0.19.5 + TAS objects + KWOK accounting
capacity; ComputeDomain `vr200-cd` (ns mokka-hetero-cd, 3 pods holding 12 Rubin);
nvml-mock releases at rev 2 (IMEX simulator, majors 255/256); DRA release rev 2
FAILED (resources applied; CD plugin crash-loops on the 6 H100/GB300 nodes).
Rollback commands: task-H8-cd-report.md.
