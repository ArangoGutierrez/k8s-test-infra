# Task H2 report: KWOK tier, DRA selectors, racks (drafts)

Status: DONE_WITH_CONCERNS (drafts done and checked offline; no cluster touched. The concerns are
the findings F1-F7 at the end: two of them change how wave 2 must install KWOK and run S3.)

Drafts: /tmp/mokka-hetero-58fc971e/h2/
Sources: /tmp/mokka-hetero-58fc971e/h2/src/ (shallow clones plus fetched files)

| Draft | Purpose |
|---|---|
| kwok/kwok-v0.8.0.yaml | release asset kwok.yaml, unchanged (sha256 a4c16e64...a426f405) |
| kwok/stage-fast-v0.8.0.yaml | release asset stage-fast.yaml, unchanged (sha256 2f28d955...fd4f54ee24) |
| kwok/stage-fast-v0.8.0-no-pod-complete.yaml | the same stages minus `pod-complete`. **Apply this one** (F1) |
| kwok/gen-nodes.sh, kwok/nodes.yaml | the 54 fake Nodes (18 vr200, 18 gb300, 18 h100) |
| dra/clone-slices.sh | clones a real node's slice onto every KWOK node of that type |
| dra/claim-templates.yaml | Namespace `mokka-hetero-sched` plus h100-x1, gb300-x1, vr200-x1, vr200-x4 |
| racks/sgpu-rack-profiles.yaml, racks/sgpu-inventory.yaml | Mokka racks |
| scenarios/s1-type-targeting.yaml, s2-fill.yaml, s2-extra.yaml, s3-rack-a.yaml, s3-rack-b.yaml | S1-S3 |
| racks/h2probe_test.go + mutate.sh, celprobe/, dra/test/ | the offline checks listed under "Verification" |

## Pinned versions

| Source | Pin | Evidence |
|---|---|---|
| KWOK | kubernetes-sigs/kwok v0.8.0 = 156033d7df7ea0e09cea82b715fe566ea68aeeb4 | `git ls-remote --tags` and `git -C kwok rev-parse HEAD` both return that sha |
| KWOK manifests | https://github.com/kubernetes-sigs/kwok/releases/download/v0.8.0/kwok.yaml and .../v0.8.0/stage-fast.yaml | downloaded (rc=0); kwok.yaml:2495 `image: registry.k8s.io/kwok/kwok:v0.8.0` |
| DRA chart | NGC `nvidia/dra-driver-nvidia-gpu` 0.5.0, appVersion 0.5.0, digest f9fd2856...cba7bfa | NGC index.yaml entry; `shasum` of the downloaded tgz gives the same digest |
| DRA source | **kubernetes-sigs/dra-driver-nvidia-gpu v0.5.0 = 90b3a5917f0cbeb73a3c669e1e63690f89d0f437** | repo named at CHANGELOG.md:94-97 of the combined tree. Chart tgz vs tag `deployments/helm/dra-driver-nvidia-gpu`: templates identical (`diff -r -I '^ *#' -B` rc=0); values.yaml differs only at :62 repository `nvcr.io/nvidia/dra-driver-nvidia-gpu` and :68 tag `"v0.5.0"` |
| Mokka | .worktrees/rack-hetero HEAD 29cc7971 (stayed clean: `git status --short | wc -l` = 0 after every probe) | |
| Kubernetes, for scheduler, claim-controller and CEL citations | v1.35.0 raw files | kindest/node:v1.35.0 is what the repo pins (deployments/kind-nvidia-cdi/Makefile:22). **H1 must confirm the server version.** |

## a) KWOK in-cluster

**Apply, in this order:**
```
kubectl apply -f kwok/kwok-v0.8.0.yaml            # 12 CRDs, SA/ClusterRole/Binding, ConfigMap, Service, FlowSchema, Deployment kube-system/kwok-controller
kubectl -n kube-system rollout status deploy/kwok-controller
kubectl apply -f kwok/stage-fast-v0.8.0-no-pod-complete.yaml   # node-heartbeat-with-lease, node-initialize, pod-delete, pod-ready
kubectl apply -f kwok/nodes.yaml
```
- The kwok-controller manages only Nodes annotated `kwok.x-k8s.io/node=fake` (kwok-v0.8.0.yaml:2423-2426 `manageAllNodes: false`, `manageNodesWithAnnotationSelector: 'kwok.x-k8s.io/node=fake'`). Its Deployment has no tolerations and no nodeSelector, so the fake-node taint keeps it on a real worker.
- Stages come only from Stage CRs (kustomize/kwok/kwok.yaml:18-19 `enableCRDs: - Stage`). The docs mark stage-fast as required (site/content/en/docs/user/kwok-in-cluster.md:39-53).
- Filtered stage file check: `python3 yaml` lists the original stages as `['node-heartbeat-with-lease','node-initialize','pod-complete','pod-delete','pod-ready']` and the filtered file as the same minus `pod-complete`. `kept docs identical: True`.

**Node template** (kwok/gen-nodes.sh, which cites every field):
- annotations `kwok.x-k8s.io/node: fake`, `node.alpha.kubernetes.io/ttl: "0"`
- labels: `kubernetes.io/hostname`, `kubernetes.io/os: linux`, `kubernetes.io/arch: amd64`, `type: kwok`, `mokka-hetero.nvidia.com/tier: kwok`, `mokka-hetero.nvidia.com/gpu-type: <t>`, `mokka.nvidia.com/sgpu-node: "true"`, `mokka.nvidia.com/pool: kwok-<t>`
- taint `kwok.x-k8s.io/node=fake:NoSchedule`
- status: capacity and allocatable `cpu: "64"`, `memory: 512Gi`, `pods: "110"`, `phase: Running`, fake nodeInfo. This is a scheduling envelope, not GPU identity; scenario pods request no cpu or memory. node-initialize keeps given values (stage-fast.yaml:107-122).
- Generated output check: 54 nodes, `{'kwok-vr200': 18, 'kwok-gb300': 18, 'kwok-h100': 18}`, `forbidden-label nodes []`.

**What keeps real DaemonSets off the fake nodes.** The taint alone does not:
- DRA kubelet plugin: tolerates only `nvidia.com/gpu` (chart values.yaml:290-293), so the taint keeps it off. Its node affinity (values.yaml:319-352: NFD pci labels, cpu vendor, `nvidia.com/gpu.present`) also matches no KWOK node.
- nvml-mock: **tolerates every taint** (nvml-mock values.yaml:67-68 `- operator: Exists`; docs/guides/device-plugin.md:176-182). What keeps it off is each release's `nodeSelector nvml-mock/profile=<p>`, so KWOK nodes must never carry `nvml-mock/profile`. gen-nodes.sh never sets it.
- Mokka control-plane Deployment: `tolerations: []` (nvml-mock values.yaml:403), so the taint keeps it off.
- INFERENCE, not read from source: kind's kube-proxy and kindnet DaemonSets tolerate everything and will get fake Running pods on the 54 nodes. That is harmless, since nothing runs.

**How a pod bound to a KWOK node reaches Running.** The scheduler binds it. KWOK plays stages only for pods whose `spec.nodeName` is a node it manages (kwok pkg/kwok/controllers/pod_controller.go:462-465, with controller.go:475-481). The `pod-ready` stage (stage-fast.yaml:204-292) matches Pending, not-Ready pods and patches status to Running with container statuses and a podIP. The IP comes from the node's `spec.podCIDR` if set, otherwise the kwok cidr (pod_controller.go:588-591; kwok.yaml cidr 10.0.0.0/24). Deletion goes through `pod-delete` (stage-fast.yaml:189-202, `delete: true`).

**DRA on fake nodes. Nothing prepares a claim, and nothing needs to.**
```
$ grep -rn -i -e NodePrepareResources -e resourceclaim -e resourceslice -e resource.k8s.io -e dynamicresource --include='*.go' .   # kwok v0.8.0, 567 .go files
grep-go rc=1                                   (no match)
$ grep -rln ResourceRef --include='*.go' pkg | head -3     # positive control, same tree
pkg/apis/v1alpha1/zz_generated.defaults.go ...
$ grep -rn -i -e resourceclaim -e resourceslice -e resource.k8s.io . (all files)
site/content/en/docs/examples/dra.md:13,21,86-123,127-196  (docs only)
```
KWOK's own DRA example (site/content/en/docs/examples/dra.md:84-206) applies a hand-written ResourceSlice for a fake node and a Deployment with a claim, then shows the claim `allocated,reserved` (:194-196) and the pod `Running` (:204-206). The scheduler allocates and reserves in its DRA plugin, and pod-ready sets Running. No kubelet exists to call NodePrepareResources. INFERENCE for k8s 1.35: that path is unchanged. The first S1 pod on a KWOK node confirms it on the cluster; if it stays Pending, check whether the scheduler needs anything from the node.

## b) ResourceSlice shape, driver 0.5.0, default gates

- Driver name `gpu.nvidia.com` (cmd/gpu-kubelet-plugin/main.go:45).
- With default gates (DynamicMIG off, featuregates.go:145-148; chart `featureGates: {}` values.yaml:121) the driver publishes **one pool named after the node with one slice holding every device** (driver.go:488-501).
- Slice metadata comes from the helper (vendored k8s.io/dynamic-resource-allocation resourceslice/resourceslicecontroller.go): `generateName <index>-gpu.nvidia.com-<node>-` (:924-931), ownerReference to the Node (:915-921; owner Kind Node from kubeletplugin/draplugin.go:1191-1195), `spec.nodeName` set, and the pool's `generation`/`resourceSliceCount` managed (:825-826, 853-868).
- Device name: `gpu-<minor>` (deviceinfo.go:122-124). Only full GPUs are published: MIG is disabled in all three profiles (nvlib.go:317-328; vr200.yaml:365-367, gb300.yaml:361-364, h100.yaml:305-308).
- **Attributes** (deviceinfo.go:168-211, values filled at nvlib.go:472-638):

| key | type | source | under Mokka |
|---|---|---|---|
| type | string "gpu" | types.go:27 | present |
| uuid | string | NVML GetUUID | present. Static per profile (see F4) |
| productName | string | NVML GetName = profile `name` (engine device.go:469-475, 165-166) | present |
| brand | string | go-nvlib GetBrandAsString. Profile `nvidia` gives BRAND_NVIDIA gives "Nvidia" (engine device.go:2231-2234; go-nvlib device.go:144-145) | present, same for all three types |
| architecture | string | go-nvlib GetArchitectureAsString (vendored v0.12.0 device.go:74-104). Profile string gives the gpuarch enum (internal/gpuarch/arch.go:56-82) | present |
| cudaComputeCapability | version | "%d.%d" through Masterminds semver | present |
| driverVersion | version | SystemGetDriverVersion through semver | present |
| cudaDriverVersion | version | major*1000+minor*10 (engine.go:289-295), rendered "%v.%v" (nvlib.go:631) | present |
| resource.kubernetes.io/pciBusID | string | NVML busId lowercased, leading "0000" trimmed (go-nvlib device.go:52,185-205). Always set; an error fails discovery (nvlib.go:547-552) | present |
| resource.kubernetes.io/pcieRoot | string | sysfs readlink (nvlib.go:554-563) | expected ABSENT: the Go plugin cannot see the shimmed sysfs (docs/helm-chart.md:1081-1095) |
| resource.kubernetes.io/numaNode | int | sysfs numa_node (numa.go:38-48) | expected ABSENT (INFERENCE: same sysfs reason) |
| addressingMode | string | only if NVML answers ATS/HMM/None (nvlib.go:540-545) | expected ABSENT: the mock's export is a stub returning NOT_SUPPORTED (bridge/stubs_generated.go:107-110, helpers.go:142-152; `grep -c Addressing engine/version.go` = 0 with grep and grep -a, so FunctionAvailable is true), and go-nvlib maps NOT_SUPPORTED to "" (device.go:165-167) |
| gpuModuleID, partitionN | int | FabricManagerPartitioning gate only (off, featuregates.go:180-183) | absent |

- **Capacity:** `memory` = NVML total bytes as a BinarySI quantity (partitions.go:34-43). No consumable-share policy, because the ConsumableShares gate is off (consumable_shares.go:40-43, featuregates.go:201-204).
- **Expected values.** I recomputed these with the driver's own vendored semver, resource and go-nvlib code (`go run ./hack/h2probe` inside the v0.5.0 clone, rc=0):
```
h100  productName="NVIDIA H100 80GB HBM3"  cudaComputeCapability=9.0.0  driverVersion=550.163.1 cudaDriverVersion=12.4.0 memory=80Gi   pciBusID 0000:1a:00.0 .. 0000:cb:00.0 (8)
gb300 productName="NVIDIA GB300 NVL"       cudaComputeCapability=10.0.0 driverVersion=570.124.6 cudaDriverVersion=12.8.0 memory=288Gi  pciBusID 0000:0a:00.0 0000:0b:00.0 0000:4a:00.0 0000:4b:00.0
vr200 productName="NVIDIA Graphics Device" cudaComputeCapability=10.7.0 driverVersion=615.23.0  cudaDriverVersion=13.4.0 memory=288Gi  pciBusID 0002:81:00.0 0002:c1:00.0 000a:81:00.0 000a:e1:00.0
```
  Architecture: h100 "Hopper", gb300 "Blackwell", vr200 "Rubin" (DEVICE_ARCH_RUBIN = 13, driver vendor go-nvml const.go:121-122). Brand is "Nvidia" for all three. On vr200, device names follow the minors (vr200.yaml:441-479 minor 0,3,1,2), so gpu-0 is 0002:81, gpu-3 is 0002:c1, gpu-1 is 000a:81 and gpu-2 is 000a:e1. **driverVersion loses the leading zero: "550.163.01" is published as 550.163.1.**
- **Clone procedure** (dra/clone-slices.sh, `clone-slices.sh <type> <real-node>`):
  - Copied verbatim: driver, device names, every attribute except uuid (pciBusID included, because it is node-local and identical trays share it), and every capacity.
  - Rewritten: a fresh metadata name `<node>-gpu.nvidia.com` with an ownerReference to the KWOK Node, so deleting the node garbage-collects its slice. Also rewritten: `spec.nodeName`, `pool.name` (the node), `pool.generation: 1`, `pool.resourceSliceCount: 1`.
  - Per-device uuid comes from the node's **SGPURack slot**: the rack GPU whose `pciAddress` equals the device's pciBusID. No identity is invented here. It follows that racks must be applied, and nodes bound, before cloning.
  - The script refuses a source that is not a single untainted slice with the expected device count, a target with no unique slot in that type's rack group, or a result whose identity differs from the source or reuses a uuid.
  - The real plugin never touches the clones: its informer filters `spec.nodeName=<own node>` (resourceslicecontroller.go:546-554).
  - The chart's ValidatingAdmissionPolicy only restricts the driver's own ServiceAccount (templates/validatingadmissionpolicy.yaml:13-16), so an admin kubeconfig can create the clones.

## c) CEL selectors (dra/claim-templates.yaml)

Each template ANDs architecture, productName and exact compute capability through `device.attributes['gpu.nvidia.com'].<attr>`. Unprefixed attributes belong to the driver domain (k8s v1.35.0 dynamic-resource-allocation/cel/compile.go:117-118, 257-261, 383-386). Versions compare with `== semver('x.y.z')` (apiserver/pkg/cel/semver.go:59-65). The API is resource.k8s.io/v1 with `exactly:`; on a v1beta1-only server, drop that level.

Evidence: celprobe compiles the templates with the k8s v0.35.0 DRA CEL compiler (after strict-decoding them into resource/v1 types) and evaluates them against the attribute sets above. rc=0:
```
selector \ device      h100   gb300  vr200  gb300-cc10.3
h100-x1                true   false  false  false
gb300-x1               false  true   false  false
vr200-x1               false  false  true   false
vr200-x4               false  false  true   false
naive:cc-major-10      false  true   true   true      <- overlap
naive:cc>=10.0         false  true   true   true      <- overlap
naive:mem-288Gi        false  true   true   true      <- overlap
naive:brand            true   true   true   true      <- overlap
naive:arch-Rubin       false  false  true   false
RESULT: every claim template matches only its own type
```
Mutation check: replacing vr200-x1's selector with `cudaComputeCapability.major() == 10` makes the probe print `vr200-x1 false true true true` and `RESULT: a claim template is not type-exclusive`, exit 1.

**Selectors that match two types:**
- memory: gb300 and vr200 are both 288Gi.
- compute-capability major 10, or anything ">= 10.0" ("Blackwell and newer"): gb300 and vr200.
- brand: all three.
- productName alone for vr200: "NVIDIA Graphics Device" is the generic string of any board the driver's table lacks (vr200.yaml:43-48).
- Architecture alone does separate the three types in this cluster.
- Also, gb300-x1 would **not** match a real GB300 that reports compute capability 10.3 (the gb300-cc10.3 column). It matches what this stack publishes, as SPEC intends.

## d) Mokka racks (racks/)

- Three SGPURackProfiles: `hetero-vr200-nvl72` (18 nodes x 4), `hetero-gb300-nvl72` (18 x 4) and `hetero-h100-hgx` (18 x 8). Every value is copied from the nvml-mock profile with its line cited. gpuSlots use the lowercase BDFs the driver publishes, plus the root complex and NUMA node from `pcie_topology`.
- One SGPUInventory `mokka-hetero` with rack groups vr200, gb300 and h100, count 1 each, disjoint selectors `mokka.nvidia.com/pool: kwok-<t>`.
- Node eligibility needs `mokka.nvidia.com/sgpu-node=true` (allocate/selectors.go:19,123) plus the pool label. gen-nodes.sh sets both.
- **What is projected onto a Node, and nothing else** (docs/mokka-controller.md:168-173; metadata/keys.go:8-13):
  - label `mokka.nvidia.com/sgpu-assigned=true`
  - label `nvidia.com/gpu.clique=<rack fabricUUID>.<cliqueID>`. cliqueID is always 0 (rack/materialize.go:250-255), and the value is formatted at projection/controller.go:792-797.
  - annotation `mokka.nvidia.com/sgpu-assignment`, compact JSON `{v, inventory, rack, profile{name,uid,revision}, rackGroup, rackIndex, nodeIndex, nodeUID}` (assignment/assignment.go:35-42, 46-64)
- **Model fields are not validated.** ValidateProfile (materialize.go:64-131, also run at reconcile.go:593) checks only nodesPerRack, gpus.count, gpuSlots (count, unique contiguous indexes, canonical lowercase PCI address and root complex), gpuFabric and network. The CRD types model fields as optional free strings; computeCapability, if present, needs major and minor. No non-test code reads the SGPURackProfile model fields:
  - `grep -rn -E "\.Model\b|\.ProductName\b|\.ComputeCapability\b|\.Architecture\b" internal cmd` (non-test) hits only internal/agent/source/file.go:286-291, which reads the nvml-mock engine.DeviceConfig, not the CRD.
  - The regex does match a synthetic `...GPUs.Model.ProductName` line (count 1).
- **What "rack" means for HGX:** H100's NVLink domain is the 8-GPU baseboard. The H100 profile has no gpuFabric because a Node-scoped fabric is admitted by the CRD enum (sgpurackprofiles CRD :507-512) but rejected at materialization (materialize.go:110-113). The H100 "rack" is a placement group of 18 nodes, and its projected clique names the rack, not an NVLink partition (F5).
- Evidence (racks/h2probe_test.go, injected with `go test -overlay` and a scratch `-modfile`, so the tree is unchanged). It checks each draft against the real CRD OpenAPI schema and its x-kubernetes-validations, then UnmarshalStrict, ValidateProfile and RenderRack:
```
group=vr200 rack=mokka-hetero-vr200-0-a7150f448270 nodes=18 gpus=72  clique=0b48e00f-...-085dcc028543.0 node0.gpu0=GPU-fc5eff9d-...@0002:81:00.0
group=gb300 rack=mokka-hetero-gb300-0-97f69dc33fb3 nodes=18 gpus=72  clique=a5ed75c3-...-46c8174e39da.0
group=h100  rack=mokka-hetero-h100-0-983a80c81b2d  nodes=18 gpus=144 clique=4513788d-...-9ce45e13f37d.0
--- PASS: TestH2RackDrafts
--- PASS: TestH2H100NodeScopedFabricIsRejected   (EqualError "gpuFabric must define a positive rack-scoped topology")
ok  ... rc=0
```
  (UIDs in the probe are fake, so real clique and UUID values will differ.) Mutation checks in racks/mutate.sh:
  - M1, uppercase `0002:C1:00.0`: rc=1, `...pciAddress in body should match '^[0-9a-f]{4}:...'`.
  - M2, dropping a vr200 slot: rc=1, `topology.gpuSlots must contain one slot per GPU`.
  - After restoring the file, cmp reports it identical and the baseline is rc=0.
- Wave-2 check: `kubectl get nodes -l mokka.nvidia.com/sgpu-node=true -L nvidia.com/gpu.clique` shows 54 nodes and exactly 3 clique values, 18 each; `sgpuinventory mokka-hetero` status capacity is nodes 54, gpus 288.

## e) Scenarios (scenarios/)

Every scenario pod tolerates the KWOK taint, so only the claim selector keeps it on its type. Pods use `busybox:1.36` (as docs/guides/dra.md:117); preload it into kind if pulls are slow.
- **S1** s1-type-targeting.yaml: Deployments s1-h100, s1-gb300 and s1-vr200, 4 replicas each, one GPU per pod. Check: every allocated result `{pool, device}` resolves to a slice device of the wanted type.
- **S2** s2-fill.yaml: Deployment with 84 replicas on vr200-x1. Precondition: S1 is deleted and exactly 84 Rubin devices exist. Once 84 claims are allocated, apply s2-extra.yaml, a single Pod. Expected: Pending, a FailedScheduling event, no allocation, while 84 GB300 devices are still free. That free GB300 capacity is what makes "never satisfied by GB300" a real test.
- **S3** s3-rack-a.yaml then s3-rack-b.yaml, never both at once. Two Indexed Jobs, each with completions and parallelism 18 and backoffLimit 0, each pod holding one vr200-x4 claim (a whole tray). Each has required podAffinity on `nvidia.com/gpu.clique` with a label unique to its own Job (`mokka-hetero.nvidia.com/s3-job: a|b`).
  - Why A cannot split: after its first pod is bound or assumed, every later pod must go to a node whose clique already has one (k8s v1.35.0 interpodaffinity/filtering.go:384-389). A node without the clique label is never feasible (:385-393). GB300 and H100 racks have cliques but no Rubin devices. B has the same priority as A, so it cannot preempt A's pods.
  - How it could still pass or fail for the wrong reason (preconditions P1-P4 in s3-rack-a.yaml):
    - P1: pod-complete is installed (F1).
    - P2: a real VR200 worker carries a clique label. B's first pod then takes the first-pod exception there (:396-404) and B runs 3 pods.
    - P3: stale pods with the same label pin the clique.
    - P4: S1 or S2 still holds devices.
  - Applying A and B together lets both first pods take the exception into the same empty rack (INFERENCE from :396-404), so B runs partially.
  - The manifest does not give gang scheduling.
- Strict decode of every scenario, claim template, the 54 Nodes and a cloned slice into k8s.io/api v0.35.0 types: `all documents decode strictly`, rc=0. Mutation check: the misspelling `resourceClaimTemplatName` gives `json: unknown field`, exit 1.

## Findings

- **F1 (changes the install): stage-fast's `pod-complete` breaks S3.** It flips every Job-owned pod on a KWOK node to Succeeded immediately (stage-fast.yaml:148-187: selector ownerReferences kind Job, no delay). Then:
  - The claim controller drops the reservation, clears the allocation and deletes the generated claim (k8s v1.35.0 pkg/controller/resourceclaim/controller.go:824-826, 864-872, 910-925).
  - The scheduler stops seeing the pod, because its informer excludes Succeeded and Failed (pkg/scheduler/scheduler.go:651-656).
  - So A's trays free up and B schedules; and with two VR200 racks a late pod of A could take the first-pod exception into the other rack.
  - Fix: apply kwok/stage-fast-v0.8.0-no-pod-complete.yaml. D2's Job runs on real nodes and is unaffected, because KWOK ignores pods on unmanaged nodes (pod_controller.go:462-465).
- **F2: the KWOK taint does not keep nvml-mock off.** It tolerates everything. Only the per-release nodeSelector does, so KWOK nodes must never carry `nvml-mock/profile`.
- **F3: S2 and S3 ordering matters.** S1 must be gone before S2, and S1/S2 before S3. S3-B only after A is fully Running.
- **F4: real-tier UUIDs repeat across nodes of the same type.** The engine takes each device UUID straight from the profile (engine.go:152-159, config.go:300-311), and the profile lists fixed UUIDs (vr200.yaml:442-472). No per-node rewrite was found in the engine or the chart templates (`grep -rn -i uuid deployments/nvml-mock/helm/nvml-mock/templates/` hits only an NRI comment). So the 3 real VR200 workers publish the same 4 UUIDs. D1 must not count distinct UUIDs cluster-wide; count devices per slice. The clones get distinct SGPURack UUIDs.
- **F5: H100 rack semantics.** Mokka cannot express a node-scoped NVLink domain (CRD admits it, ValidateProfile rejects it; probe test above). The H100 group therefore has no gpuFabric, and its projected `nvidia.com/gpu.clique` is a rack id, not an NVLink partition. It does not affect S3, which is VR200 only.
- **F6: driverVersion normalization.** The DRA attribute is 550.163.1, not 550.163.01. D1's expected values must use the published form.
- **F7 (doc drift, outside this task):** Mokka docs name the attribute `dra.k8s.io/pcieRoot` (docs/helm-chart.md:1095, CHANGELOG.md:881), but driver v0.5.0's vendored deviceattribute publishes `resource.kubernetes.io/pcieRoot` (attribute.go:25-32).
- **For H1:**
  - The Mokka control plane needs `controlPlane.image.tag` with `allowMutableTag: true`, or a digest (nvml-mock values.yaml:362-371).
  - The actual kind server version decides v1 vs v1beta1 for the templates.
  - One real slice per type confirms the attribute table above: pcieRoot, numaNode and addressingMode are expected absent.

## Verification (all run against the final draft state)

| Check | Command | Result |
|---|---|---|
| Rack drafts vs CRD schema + CEL + controller | `go test -modfile=racks/probe.go.mod -mod=mod -overlay racks/overlay.json -run TestH2 ./internal/controlplane/api/v1alpha1/` (in the worktree) | rc=0, 2 PASS; worktree status 0 lines |
| Rack probe discriminates | racks/mutate.sh | M1 rc=1, M2 rc=1, restored baseline rc=0 |
| Claim selectors type-exclusive | `celprobe: go run . ../dra/claim-templates.yaml` | rc=0; mutant rc=1 |
| All manifests strict-decode | `celprobe: go run ./decode ...` | rc=0; mutant rc=1 |
| Clone script | dra/test with a fake kubectl (PATH shim) and a vr200 fixture | happy path rc=0, uuids from the rack joined on pciBusID; N1 unmatched BDF rc=5 (jq error), N2 unbound target rc=1, N4 duplicate uuid rc=1 |
| Driver attribute strings | `go run ./hack/h2probe` in the dra-driver v0.5.0 clone (vendored deps) | rc=0, table in b) |

Not verified, because it needs the cluster (wave 2): the KWOK controller on k8s 1.35, real slice contents, Mokka projection with real UIDs, and S1-S3 themselves.
