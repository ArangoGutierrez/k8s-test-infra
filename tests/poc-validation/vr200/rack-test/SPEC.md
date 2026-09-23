# Spec: heterogeneous Mokka cluster with a full VR200 rack (2026-09-23)

Design decisions (made during the spike):
run on a remote VM <vm> (cleaned: 0 containers, 12.7 GB RAM free,
4 CPUs, x86_64, 244 GB disk); one kind cluster with Mokka + KWOK; GPU identity
published through DRA ResourceSlices (not GFD).

## Goal

Test VR200 detection and scheduling correctness in a heterogeneous cluster that
is 1/3 H100, 1/3 GB300, 1/3 VR200 and contains one full VR200 rack.

## Topology (one kind cluster, name `mokka-hetero`)

- Real tier (kind nodes, containers run): 1 control-plane + 9 workers:
  3 H100 (8 GPUs each), 3 GB300 (4 each), 3 VR200 (4 each). One nvml-mock Helm
  release per profile, each selecting its nodes (the device-plugin guide's fleet
  pattern). DRA driver `dra-driver-nvidia-gpu` 0.5.0 (docs/guides/dra.md:68-69)
  publishes ResourceSlices from Mokka's NVML on every real node.
- KWOK tier (fake kubelets, no containers, same API server and scheduler): 54
  nodes: one full VR200 rack (18 trays x 4 GPUs = 72), one GB300 rack (18 x 4),
  18 H100 nodes (x 8). Each KWOK node's ResourceSlice is cloned from a real
  node of the same type (identity is never invented), with nodeName, pool and
  per-device unique fields rewritten.
- Racks: Mokka's control plane (#690) with SGPURackProfile / SGPUInventory
  assigns the KWOK trays to racks and projects `nvidia.com/gpu.clique` (one
  value per rack).
- Totals: 21 nodes per type; 84 VR200 + 84 GB300 + 168 H100 = 336 GPUs.

## Source

upstream/main e8e49aeb + PR #872's 4 commits (cherry-pick verified clean
locally in .worktrees/rack-hetero, HEAD 29cc7971). Never pushed. On the VM the
same tree is rebuilt from GitHub (clone + fetch pull/872/head + cherry-pick).

## Checks (each one exits non-zero on failure; each guard mutation-verified)

Detection (real tier):
- D1 ResourceSlice attributes per type match fixed expected values (product
  name, architecture, compute capability, memory, count). VR200 must differ from
  GB300 on name, architecture and compute capability (both have 288 GiB).
- D2 vLLM v0.30.0 discovery Job on one node per type (DRA-allocated devices,
  NVML-only + image compat libcuda exposure proven in the spike): platform,
  name, CC, memory and feature gates per type.
- D3 mutation: repoint one VR200 worker at the gb300 profile; D1/D2 must fail.

Scheduling (real + KWOK, one scheduler):
- S1 type targeting: ResourceClaimTemplates with CEL selectors per type; pods
  land only on devices of that type.
- S2 no spill: fill every VR200 device (84); the next VR200 claim stays Pending
  with a scheduling-failure event and is never satisfied by GB300.
- S3 rack locality: an 18-pod job, each pod 4 VR200 GPUs, required pod affinity
  on `nvidia.com/gpu.clique`, lands entirely in the VR200 rack; a second such
  job stays Pending instead of splitting across racks.

## Out of scope

GFD labels (DRA chosen), SGLang detection (its only NVML-derived value is
memory, already proven), CUDA execution, pushing or posting anything.

## Known unknowns (findings, not blockers)

- Whether the DRA driver's attributes identify VR200 correctly (PR #872 says
  0.5.0 resolves NVML architecture enum 13).
- Mokka's gb300 profile reports compute capability 10.0; real GB300 may report
  10.3. Unverified; the detection tier will show what the stack believes.
- Under CDI injection the mock may lose MOCK_NVML_CONFIG (#747) and fall back
  to an A100 identity inside pods (task B); D2 must check identity first.
