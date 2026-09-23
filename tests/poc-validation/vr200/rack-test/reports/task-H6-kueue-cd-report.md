# Task H6 report: Kueue TAS and ComputeDomain on `mokka-hetero` (research + drafts)

Status: **DONE_WITH_CONCERNS** (2026-09-23, ~13:25Z to 15:45Z). Local work only:
the VM and the cluster were never touched, and no draft has run on the cluster.
Offline checks whose guards I saw go RED on a mutant: the Kueue probe (M1, M2),
the Kueue validator (2 mutants), the k3 jq checks (3 + 1 mutants), the k0 promoter
grep and the k1 index check, and the ComputeDomain strict decode. Checked only by `bash -n` and
`shellcheck`, with no mutant: the k2, k7, c1, c2 and c4 scripts. One mutant
SURVIVED: CRD CEL rules are not covered locally (Risk 4). The concerns are
listed under "Risks" and "Source-verified vs INFERENCE".

Drafts: `/tmp/mokka-hetero-58fc971e/h6/{kueue,cd,kueue-probe}/`
Sources (shallow clones, scratch): `/tmp/mokka-hetero-58fc971e/h6/src/`

## Recommendations

- **Part A (Kueue TAS): design (b).** Give each KWOK tray a per-type accounting
  extended resource (`mokka-hetero.nvidia.com/tas-vr200-gpu: 4`). Set the value
  from that node's own ResourceSlice and re-check it before each run. Pods
  request that resource AND keep their DRA claim. Kueue v0.19.5 TAS cannot see
  DRA devices at all. I ran Kueue's real scheduler on a model of this cluster:
  - Design (b) is the only one that admits an 18-tray job one pod per tray
    inside one rack.
  - Design (a) (DRAExtendedResource) is never admitted.
  - Design (c) (Kueue's own DRA quota) either is never admitted, or stacks all
    18 pods on ONE tray.
- **Part B (ComputeDomain): design B-1.** Run the upstream DRA driver v0.5.0
  ComputeDomain path (CRD, controller, CD kubelet plugin, CD daemons) on the 3
  real VR200 workers:
  - IMEX: real `nvidia-imex --nogpu` through Mokka's
    `Dockerfile.compute-domain-daemon` overlay.
  - IMEX surface: Mokka's IMEX simulator plus `altProcDevices`.
  - Where it runs: the existing cluster, in place. No fresh cluster, no node
    container restart, and NRI is not needed.
  - What it does not prove: anything about the KWOK rack. KWOK runs no
    containers, so no IMEX daemon can run there.

## Pins

| Source | Pin | Evidence |
|---|---|---|
| Kueue | **v0.19.5**, commit **8e60d76a91bb9a45754218e569de1088f862ac75** (tag object cd936efc). This is the latest release, 2026-09-17 | `gh release list -R kubernetes-sigs/kueue` shows `v0.19.5 Latest 2026-09-17T14:55:26Z`; `git ls-remote --tags` shows `8e60d76a... refs/tags/v0.19.5^{}`; the clone's HEAD is 8e60d76a |
| Kueue pre-release (cross-check only) | v0.20.0-rc.1 = 02587ad4811ff68070381207ec684987d219ad38 | ls-remote |
| Kueue release assets | `manifests.yaml` sha256 7df370a1...8225a; `kueue-0.19.5.tgz` sha256 1c97fb12...1048e0 | `gh release download` + `shasum -a 256` |
| Kueue image | `registry.k8s.io/kueue/kueue:v0.19.5`, the ONLY image the chart renders with my values. Promoted index `sha256:a55949705d7ab1fe38034da56c5af95deecec3da0abebb209a372f7a5c414a2d`; linux/amd64 manifest `sha256:6ac15f950a8e904f994ccfa3bfe71a1a4129a09654ee5c3be1a492e329f03a11` | promoter: kubernetes/k8s.io main@34e1e12a `registry.k8s.io/images/k8s-staging-kueue/images.yaml:159`. Index fetched from registry.k8s.io on the Mac: raw bytes hash to the pin (see "Kueue image path") |
| Kubernetes | v1.36.1 = 756939600b9a7180fc2df6550a4585b638875e67 (sparse clone) | ls-remote `v1.36.1^{}`. The cluster runs v1.36.1 (H1) |
| DRA driver | kubernetes-sigs/dra-driver-nvidia-gpu v0.5.0 = 90b3a5917f0cbeb73a3c669e1e63690f89d0f437 | fresh clone HEAD, same as H2 |
| containerd | v2.3.1 = 64b425cf570b3b8dd1d4cc46da7c1fce65c6651a (sparse); kind nodes run containerd 2.3.1 (H1) | ls-remote |
| kind | v0.32.0 = cda67ef8 (only `images/base/files/etc/containerd/config.toml` fetched) | ls-remote |
| Mokka | .worktrees/rack-hetero HEAD 29cc7971 | `git rev-parse HEAD` |

---

## Part A1: how Kueue TAS computes capacity, and whether it sees DRA

All paths below are in Kueue v0.19.5 unless noted.

1. **Per-node capacity is `node.status.allocatable`, and nothing else.**
   - Source: `pkg/cache/scheduler/tas_topology_tree.go:167-168`
     `capacity := resources.NewRequestsFromResourceList(node.Status.Allocatable)`.
   - Each leaf starts at that value (`tas_flavor_snapshot.go:254`).
   - Non-TAS pod requests are subtracted (`:260-265`; field doc at `:90-93`:
     "total node capacity minus the non-TAS usage ... static Pods, DaemonSets,
     or Deployments").
   - The node cache keeps only Name, Labels, Taints and Allocatable
     (`tas_nodes_cache.go:131-149`).
2. **Per-pod demand is the pod spec, not the quota charge.**
   - Source: `pkg/scheduler/flavorassigner/tas_flavorassigner.go:111-112`
     `// Use PodSpec directly for TAS placement, not quota-filtered admission values.`
     `singlePodRequests := resources.NewRequestsFromPodSpec(&podSet.Template.Spec)`.
   - `resources.NewRequestsFromPodSpec` is `resourcehelpers.PodRequests`, which
     has no DRA term (`pkg/resources/factory.go:71-76`).
   - TAS adds one `pods` unit per pod (`tas_flavor_snapshot.go:936-937`).
3. **A requested resource that is missing from allocatable fits zero times.**
   - `pkg/resources/requests.go:195-219`: `count = max(0, cap/rValue)`.
   - An EMPTY request list also returns 0 (`:227`
     `return ptr.Deref(result, 0), ...`). Case c of the probe below shows the
     effect.
4. **DRA is quota-only in Kueue; TAS never sees it.**
   - Where the quota charge comes from:
     - DRA claims are charged to quota under the `deviceClassMappings` name
       (`pkg/workload/workload.go:740-757`).
     - The workload is queued with `WithPreprocessedDRAResources`
       (`pkg/controller/core/workload_controller.go:582-586`).
   - A search of all TAS code for DRA terms finds only a comment:
     ```
     $ grep -rn -E '\bDRA\b|ResourceClaim|DeviceClass|KueueDRA|pkg/dra|dra\.' pkg/scheduler/flavorassigner/ pkg/cache/scheduler/ pkg/util/tas/ pkg/controller/tas/ pkg/controller/jobframework/tas*.go | grep -v _test.go
     pkg/cache/scheduler/was/scheduling_simulator.go:77:	// In the future, when using plugins like DRA, which rely on the informers,
     == positive control: the same pattern over all non-test files in pkg/ lists 24 files
     (pkg/dra/claims.go, pkg/dra/mapper.go, pkg/workload/workload.go, pkg/controller/core/workload_controller.go, ...)
     ```
   - The node-feasibility simulator runs only the NodeUnschedulable,
     TaintToleration and NodeAffinity plugins (`was/scheduling_simulator.go:49-56`).
   - Kueue's docs say the same:
     `site/content/en/docs/concepts/dynamic_resource_allocation.md:268-270`
     "**No DRA + Topology Aware Scheduling (TAS)**: DRA resources are not
     accounted for in TAS capacity calculations." The KEP agrees:
     `keps/2941-DRA/README.md:246-247` and `:309`, with "TAS + DRA integration"
     listed only under GA (`:1947`).
   - v0.20.0-rc.1 has not changed this:
     - the same doc text at `:268-270`;
     - the same `NewRequestsFromPodSpec` call at `tas_flavorassigner.go:114`;
     - the only DRA hits in TAS code are comments at
       `was/scheduling_simulator.go:135,168`.
5. **Feature gates at v0.19.5** (`pkg/features/kube_features.go`):

   | Gate | State | Lines |
   |---|---|---|
   | `TopologyAwareScheduling` | Beta, on since 0.14 | `:745-747` |
   | `KueueDRAIntegration` | Beta, on | `:807-808` |
   | `KueueDRAIntegrationExtendedResource` | Beta, on since 0.19 | `:810-812` |
   | `KueueDRARejectWorkloadsWhenDRADisabled` | Beta, on | `:818-819` |
6. **Every design that keeps DRA claims must map the claim's DeviceClass.**
   - With `KueueDRAIntegration` on, an unmapped DeviceClass makes the Workload
     inadmissible: `pkg/dra/claims.go:213-219` ("DeviceClass %s is not mapped in
     DRA configuration"), applied at `workload_controller.go:476-490`.
   - Turning the gate off does not help. `KueueDRARejectWorkloadsWhenDRADisabled`
     then rejects any workload with DRA (`workload_controller.go:432-449`).
   - Kueue also checks, cluster-wide, that at least `count` devices match each
     claim's CEL (`pkg/dra/claims.go:497-507`).
7. **A TAS flavor drops every node that lacks a level label**
   (`pkg/util/tas/node.go:35-47`). With levels
   `[nvidia.com/gpu.clique, kubernetes.io/hostname]`, the 10 real nodes (no
   clique, per H3) are outside the TAS flavor.
8. **Names at v0.19.5**:
   - Annotation `kueue.x-k8s.io/podset-required-topology`
     (`apis/kueue/v1beta2/topology_types.go:28`).
   - The hostname level must be the last level (`:48`).
   - Scheduling gate `kueue.x-k8s.io/topology` (`:75`).
   - Storage version is v1beta2 (`topology_types.go:140`,
     `resourceflavor_types.go:27`, `clusterqueue_types.go:599`).
   - After admission the ungater adds the domain labels to each pod's
     nodeSelector (`pkg/controller/tas/topology_ungater.go:309-316`).

### Kubernetes v1.36.1: DRAExtendedResource

- **Beta, on by default in 1.36**: `pkg/features/kube_features.go:1374-1377`
  (`{1.34 Alpha false}`, `{1.36 Beta true}`); it depends on
  DynamicResourceAllocation (`:2443`).
- **The scheduler hands an extended resource to DRA only when the node's
  allocatable does NOT carry it** and a DeviceClass maps it
  (`pkg/scheduler/framework/plugins/noderesources/fit.go:270-292`, used at
  `:749-751`). A node that advertises the name is served by the device-plugin
  path instead.
- **Nothing publishes a DRA-backed extended resource into Node allocatable:**
  ```
  $ grep -rn -E 'DeviceClass|ExtendedResourceName|DRAExtendedResource|resource.k8s.io|dynamicresource' pkg/kubelet/nodestatus/ --include='*.go' | grep -v _test
  pkg/kubelet/nodestatus/setters.go:301:			if !found && v1helper.IsExtendedResourceName(k) {
  ```
  The only hit is the generic rule that drops allocatable keys absent from
  capacity. Positive control:
  `grep -c -E 'IsExtendedResourceName|ScalarResource|devicePluginResourceCapacity' setters.go` = 3.
- **On a REAL node, a manual extended resource must be set in `status.capacity`.**
  The kubelet rebuilds allocatable from capacity (`setters.go:305-315`) and
  deletes allocatable-only extended keys (`:297-303`).
- **KWOK keeps both fields.** Stage `node-initialize` echoes the existing
  allocatable and capacity
  (`h2/kwok/stage-fast-v0.8.0-no-pod-complete.yaml:107-122`), and
  `node-heartbeat-with-lease` (`:10-45`) writes only conditions, addresses and
  daemonEndpoints.
- **The DRA driver chart already maps `nvidia.com/gpu`, to ANY GPU type.**
  - Source: `deployments/helm/dra-driver-nvidia-gpu/templates/deviceclass-gpu.yaml:7,12-14`
    (v0.5.0) sets `extendedResourceName: nvidia.com/gpu` on DeviceClass
    `gpu.nvidia.com` whenever the chart picks resource.k8s.io/v1
    (`_helpers.tpl:187-198`).
  - I confirmed it by rendering: `helm template` of the chart 0.5.0 with
    `--api-versions resource.k8s.io/v1` prints
    `DeviceClass gpu.nvidia.com nvidia.com/gpu`.
  - INFERENCE, since I did not read the cluster: the live class carries it, so
    on this cluster a pod that asks for `nvidia.com/gpu: N` gets DRA devices of
    any type. Check read-only:
    `kubectl get deviceclass gpu.nvidia.com -o jsonpath='{.spec.extendedResourceName}'`
    (this is step 1 of k2).

### Executed probe: Kueue v0.19.5's real scheduler on a model of the VR200 tier

The probe is `/tmp/mokka-hetero-58fc971e/h6/kueue-probe/zz_h6_probe_test.go`
(sha256 5aab1f2f...ecb52). I copied it into `pkg/scheduler/` of the scratch
v0.19.5 clone; it is committed nowhere. The model:
- 18 KWOK-like trays, each with the live VR200 clique label
  `6b0453b6-...5739.0`, a hostname, the kwok taint and allocatable cpu 64 / pods 110;
- the 3 real VR200 workers, with no clique label;
- Topology `[nvidia.com/gpu.clique, kubernetes.io/hostname]` and a TAS flavor
  on `mokka-hetero.nvidia.com/gpu-type=vr200`.

Each case runs `scheduler.schedule()`. Final run on the final file
(`probe-final.log`, rc=0):

```
--- PASS: TestH6Probe/b/18_trays,_shadow_resource,_required_clique
      admitted; resourceUsage=map[mokka-hetero.nvidia.com/tas-gpu:72] levels=[kubernetes.io/hostname]
      per-host pod counts: kwok-vr200-00=1 kwok-vr200-01=1 ... kwok-vr200-17=1         (18 hosts, one clique)
--- PASS: TestH6Probe/b/19_trays,_shadow_resource,_required_clique_(21_trays_exist,_18_in_the_rack)
      QuotaReserved=False reason=Pending msg="couldn't assign flavors to pod set main: topology \"vr200-rack\" allows to fit only 18 out of 19 pod(s)"
--- PASS: TestH6Probe/b/19_trays,_shadow_resource,_PREFERRED_clique_(real_nodes_lack_the_level_label)
      QuotaReserved=False ... "allows to fit only 18 out of 19 pod(s)"            (the real workers are invisible even as fallback)
--- PASS: TestH6Probe/a/18_trays,_nvidia.com/gpu_request,_no_allocatable_(DRAExtendedResource_shape)
      QuotaReserved=False ... "doesn't allow to fit any of 18 pod(s). Total nodes: 18; excluded: resource \"nvidia.com/gpu\": 18"
--- PASS: TestH6Probe/c/18_trays,_DRA_claim_only_(no_container_requests),_quota_via_deviceClassMappings
      QuotaReserved=False reason=Pending msg="Workload no longer fits after processing another workload"
--- PASS: TestH6Probe/c2/18_trays,_DRA_claim_+_cpu_100m,_quota_charged_via_deviceClassMappings
      admitted; resourceUsage=map[cpu:1800m mokka-hetero.nvidia.com/vr200-dra-gpu:72]
      per-host pod counts: kwok-vr200-00=18                                         (18 four-GPU pods on ONE 4-GPU tray)
--- PASS: TestH6Probe/q0/18_pods_with_no_requests_at_all,_no_DRA
      QuotaReserved=False ... "failed to assign flavors to pod set main: no TAS flavor assigned"
--- PASS: TestH6ProbeSecondJob
      tas-a admitted: usage=map[mokka-hetero.nvidia.com/tas-gpu:72]
      tas-b QuotaReserved=False msg="couldn't assign flavors to pod set main: topology \"mokka-hetero-rack\" doesn't allow to fit any of 18 pod(s). Total nodes: 18; excluded: resource \"mokka-hetero.nvidia.com/tas-gpu\": 18"
ok  sigs.k8s.io/kueue/pkg/scheduler 1.584s
```

How the harness handles DRA, and how I checked the probe itself:
- **DRA path in the harness.** The queue manager diverts a DRA workload to a
  reconcile channel (`pkg/cache/queue/manager.go:547-555`). The probe does
  instead what the workload controller does: it creates the workload after the
  LocalQueue and calls `AddOrUpdateWorkload(..., WithPreprocessedDRAResources)`.
  The first two runs hung there, and runs 3-5 fixed the harness; logs
  `probe-run1..5.log`.
- **Case c** is a Kueue quirk, not DRA-specific: a TAS pod set with no container
  requests is nominated on the DRA quota, then fails the post-nomination fit
  (`pkg/scheduler/scheduler.go:746` "Re-computing the assignment as it doesn't
  fit for TAS", then `:496` "no longer fits"). This matches the empty-request
  `CountIn` = 0 of item 3. INFERENCE: probably unintended upstream behaviour.
  Observed in the harness only.
- **Guard M1** (`probe-mutant-m1.log`). With shadow allocatable 8 instead of 4,
  TAS puts `kwok-vr200-00=2 ... kwok-vr200-08=2`, and b/18 and b/19 both FAIL.
  So "one pod per tray" is carried entirely by the declared number.
- **Guard M2** (`probe-mutant-m2.log`). With quota 72 instead of 144, tas-b is
  held by `"insufficient unused quota for mokka-hetero.nvidia.com/tas-gpu in
  flavor vr200-rack, 72 more needed"`, and the topology-reason assertion FAILs.
  So the second-job check tells quota and topology apart.

## Part A2: designs for "Kueue TAS places an 18-tray VR200 job inside one rack"

| | Design | What happens here (executed) | What it proves | What makes it theater |
|---|---|---|---|---|
| (a) | DRAExtendedResource: pods request an extended resource, and a DeviceClass with `extendedResourceName` maps it. Kueue quota comes from `KueueDRAIntegrationExtendedResource` | **Never admitted**: probe case a, "excluded: resource nvidia.com/gpu: 18". TAS counts allocatable (A1 item 1), and nothing puts a DRA-backed name there (A1, k8s section) | Nothing about TAS | The fix that seems obvious, patching node allocatable with the SAME name, makes the scheduler treat it as a device-plugin resource on those nodes (fit.go:280-283). DRA then allocates no device, and the job "passes" with zero GPUs. It would also shadow the chart's `nvidia.com/gpu` mapping cluster-wide |
| (b) | Separate per-type accounting resource on the nodes, plus the DRA claim in each pod. **RECOMMENDED** | Admitted, 1 pod per tray, 18 trays in one clique. 19 trays refused. A second 18-tray job is held by TOPOLOGY while quota has room (probe) | Kueue TAS picks one rack and one tray per pod from the capacity we declare. The kube-scheduler and DRA then allocate the real (cloned) devices on the node Kueue chose. k7 T2 checks that each pod's 4 devices come from its own node | (1) The accounting value drifts from the slices: guard M1 shows TAS then packs 2 pods per tray. k3 sets the value FROM each slice, and k7 T0 re-checks equality. (2) DRA use outside Kueue is invisible to TAS: k6 shows it. (3) Quota at 72 would make "B waits" a quota test: guard M2. (4) Asserting only "admitted": T2 asserts nodes, clique and claim pools |
| (c) | Kueue's own DRA integration (`deviceClassMappings`) with TAS | Pods without requests are **never admitted** (case c). With any small request, **admitted with 18 pods on ONE tray** (case c2): the kube-scheduler could bind 1 and 17 would stay Pending forever | Only that Kueue charges DRA devices to quota | "Kueue admitted it" while the job cannot run. Kueue's docs warn about exactly this (`dynamic_resource_allocation.md:268-270`) |
| (c') | (c) plus forced node exclusivity through a non-GPU proxy, e.g. cpu 33 of a KWOK node's 64 | Not run. INFERENCE from items 1-3: one pod per KWOK node | Placement driven by CPU, not GPUs | This is (b) with a proxy unrelated to GPUs: real workers (cpu 4) can never fit, and a CPU change silently changes "rack" behaviour |
| (d) | No TAS: Kueue quota and gang admission, with H2's S3 required podAffinity on the clique | Not run | Rack locality comes from the kube-scheduler, not Kueue | Calling it "Kueue TAS" would be theater. It stays a fallback if (b) is rejected |

**Why (b):** it is the only design where Kueue's TAS algorithm itself decides
the rack and the tray, and it keeps the DRA devices real. What it does NOT prove:
- that Kueue understands DRA (it does not, at any released version);
- anything about the real VR200 workers: they are outside the TAS flavor
  because they have no clique label. Adding one would break S3's P2.

## Part A3: drafts (`/tmp/mokka-hetero-58fc971e/h6/kueue/`)

Labels relied on (from H1/H3 evidence):
- **KWOK trays**:
  - `mokka-hetero.nvidia.com/gpu-type=<t>` (gen-nodes-h3.sh);
  - `nvidia.com/gpu.clique` (Mokka projection; 1 value per rack, 18 nodes);
  - `kubernetes.io/hostname`;
  - taint `kwok.x-k8s.io/node=fake:NoSchedule`.
- **Real workers**: only `nvml-mock/profile=<t>` and `nvidia.com/gpu.present`
  (kind-mokka-hetero.yaml). They have no clique label (H3).
- **There is NO label that the real and the KWOK nodes of a type share today.**
  The flavors use `gpu-type`, which in practice means KWOK only. The TAS level
  labels exclude the real nodes anyway.

| File | What |
|---|---|
| `values-kueue.yaml` | Helm values for the local `kueue-0.19.5.tgz`. Sets `managedJobsNamespaceSelector` to `mokka-hetero-kueue`, `frameworks: ["batch/job"]`, and `deviceClassMappings: [{name: mokka-hetero.nvidia.com/dra-gpu, deviceClassNames: [gpu.nvidia.com]}]` |
| `k0-fetch-kueue-oci.sh` | HOST side (the Mac, or anything that reaches registry.k8s.io). Builds a linux/amd64 OCI-layout tar of the official image. The index must hash to the promoter pin, and the manifest, config and 14 layers are each checked by sha256 and size. `index.json` names the image `registry.k8s.io/kueue/kueue:v0.19.5`. Already run: `kueue-v0.19.5-amd64.oci.tar`, sha256 `8265c380...d244ed`, 63229952 bytes |
| `k1-kueue-image.sh` | VM side. Checks the tar's sha256, that index.json names `registry.k8s.io/kueue/kueue:v0.19.5` at `sha256:6ac15f95...3a11`, runs `kind load image-archive` on all 10 nodes, then checks each node's `ctr images ls` shows that name at that digest |
| `k2-kueue-install.sh` | Helm install, with checks on the live objects: webhook scope, pod webhooks set to Ignore, the mapping loaded. Also records the DeviceClass `extendedResourceName` and the DRAExtendedResource metric |
| `k3-shadow-capacity.sh` | Patches `mokka-hetero.nvidia.com/tas-<type>-gpu` = the node's slice device count into capacity and allocatable on the 54 KWOK nodes. Then checks the value equals the slice count on each of the 54, and that no real node has any `tas-*` key |
| `k4-tas-objects.yaml` | Namespace, `vr200-x4` RCT copy, Topology `mokka-hetero-rack` `[nvidia.com/gpu.clique, kubernetes.io/hostname]`, flavors `vr200-rack`/`gb300-rack`/`h100-group`, one ClusterQueue and one LocalQueue per type. Quota is **2x the rack (144)**, so TAS, not quota, must hold the second job |
| `k5-job-a.yaml` / `k5-job-b.yaml` / `k5-job-c19.yaml` | Indexed Jobs, annotation `kueue.x-k8s.io/podset-required-topology: nvidia.com/gpu.clique`, `tas-vr200-gpu: 4` (requests = limits), claim `vr200-x4`, kwok toleration |
| `k6-blindspot-pod.yaml` | OPTIONAL probe of (b)'s blind spot, a plain pod holding a tray. The "hidden" variant has no accounting request: tas-a is admitted and 1 pod stays Pending. The "visible" variant has it: tas-a is not admitted ("17 out of 18") |
| `k7-tas-check.sh` | T0 preconditions (rack empty, accounting == slices, queue empty). T1 c19 held with "allows to fit only 18 out of 19 pod(s)". T2 A admitted: 18 Running, 18 distinct `kwok-vr200-*`, one clique equal to the SGPURack's `fabricUUID.cliqueID`, hostname selector == bound node, 18 claims x 4 devices from the pod's own pool. T3 B held with `topology "mokka-hetero-rack" doesn't allow to fit any of 18 pod(s)` while the reservation is 72 of 144. T4 B admitted once A is deleted |

Offline checks run on the final files:

```
helm template (my values): 43 webhooks, 0 scoped to anything but mokka-hetero-kueue; mpod/vpod/mdeployment/vdeployment/mstatefulset/vstatefulset failurePolicy=Ignore;
  the 8 without a namespaceSelector cover only clusterqueues/resourceflavors/workloads/cohorts
  positive control (chart defaults): 36 webhooks not scoped, pod/deployment/statefulset with failurePolicy=Fail
Kueue validator (hack/h6validate in the clone: Kueue's own config.Load + config.Validate, strict decode,
  webhooks.ValidateClusterQueue/ValidateResourceFlavor, hostname-last): RESULT fail=0
  mutants: topologyNme -> 'strict decoding error: unknown field "spec.topologyNme"';
           frameworks "batch/jb" -> 'config.Validate: integrations.frameworks[0]: Unsupported value: "batch/jb"'
  NOT covered (mutant survived): CRD CEL rules, e.g. coveredResources vs flavors[].resources.
  -> apply k4 with `kubectl apply --dry-run=server` first on the cluster.
k3 jq check on fixtures: good -> 3x PASS; M1 (h100 4 != slice 8), M2 (vr200 node carries the gb300 key),
  M3 (real node carries a tas key) -> each FAIL. Slice-count jq on H1's real slices: 8/8/8/4/4/4/4/4/4.
k0 promoter grep (the same string k1 used before it moved): real digest rc=0; one-nibble mutant rc=1.
k0 run on the Mac (k0-run1.log, rc=0): PASS promoter pin; PASS index bytes hash to the pin;
  amd64 child sha256:6ac15f95...3a11 (OCI manifest, 2939 bytes); PASS manifest + 15 blobs by sha256 and size.
k1 checks on the real tar: `shasum -a 256 -c` OK; index.json check PASS; a copy renamed to v0.19.4 is rejected.
Import positive control: a copy of the tar renamed to h6-probe.local/kueue:oci-import-test, loaded with
  `docker load` (Docker 29.6.2, containerd image store), came up under that name at digest sha256:6ac15f95...3a11.
  I then removed the test tag. The existing registry.k8s.io/kueue/kueue:v0.19.5 on the Mac, same digest, was not touched.
  This works because containerd import names an image from the io.containerd.image.name annotation
  (containerd v2.3.1 client/import.go:275-279), the importer `kind load image-archive` uses.
k3 InternalIP guard on fixtures: a 172.18.250.1 node passes; a node with the controller pod IP 10.244.2.6 is reported.
k7 T1/T3 matchers against the probe's exact strings: topology message matches; quota message rejected.
bash -n: all scripts rc=0; shellcheck -S warning: rc=0.
```

Step list for Part A on the VM. Run it after H5's S1-S3 are finished and deleted;
T0 enforces that.
0. HOST side, already done on the Mac: `bash k0-fetch-kueue-oci.sh`. Re-run it if the
   tar is lost; it needs only curl and python3.
1. Copy `h6/kueue/` to `~/mokka-hetero/h6/kueue/` with `tsh scp`, including
   `kueue-v0.19.5-amd64.oci.tar` and its `.sha256`.
2. `bash k1-kueue-image.sh`
3. `bash k2-kueue-install.sh`
4. `bash k3-shadow-capacity.sh`
5. `kubectl apply --dry-run=server -f k4-tas-objects.yaml && kubectl apply -f k4-tas-objects.yaml`
6. `bash k7-tas-check.sh`
7. Optional: the k6 pair.

Readiness evidence: `DONE fail=0` with 10 PASS lines (T0 x3, T1, T2 x2, T3 x3,
T4; `grep -c 'pass "' k7-tas-check.sh` = 10), plus the k3 line
`kwok nodes verified: 54 (want 54)` and `PASS all KWOK InternalIPs still 172.18.250.x`.

KWOK constraints (chief, 2026-09-23):
- **Fake nodes keep H3's preset InternalIPs 172.18.250.x.** Nothing in H6 applies
  H2's nodes.yaml. k3's status patch is a JSON merge patch that names only
  `capacity` and `allocatable`, so `addresses` stays as it is, and k3 then fails
  if any KWOK InternalIP is no longer 172.18.250.x.
- **No `kubectl logs` or `exec` on KWOK pods.** The only such call in the Kueue
  scripts is `kubectl -n kueue-system logs deploy/kueue-controller-manager` (k2),
  and that Deployment has no tolerations in the render, so it cannot land on a
  tainted KWOK node:
  ```
  $ grep -nE 'kubectl[^|]* (exec|logs) ' k*.sh
  k2-kueue-install.sh:46:kubectl -n kueue-system logs deploy/kueue-controller-manager --tail=400 | ...
  (positive control: the same pattern counts 1 in c2 and 3 in c4)
  ```
  All k7 checks read the API objects instead: Workload conditions, pod
  nodeName and nodeSelector, ResourceClaim allocations, and SGPURack identity.
  The ComputeDomain scripts exec only into pods on real workers: daemon pods
  pinned by the CD node label, workload pods on `nvml-mock/profile: vr200`, and
  c5 pods pinned by hostname to worker9 and worker6.

### Kueue image path the VM can use (verified)

| Candidate | Result from the Mac (2026-09-23 ~15:50Z) |
|---|---|
| `gcr.io/k8s-staging-kueue/kueue` (H3's pattern) | token length 0, `tags/list` http=401 "No valid credential was supplied". Positive control in the same run: `gcr.io/k8s-staging-kwok/kwok` gives token length 268, tags/list 200 (849 tags, v0.8.0 present), and H3's pinned index 200 |
| `us-central1-docker.pkg.dev/k8s-staging-images/kueue/kueue` (the real promoter source) | http=200, index bytes hash to the pin. It is a *.pkg.dev host, so it is reset on the VM |
| `registry.k8s.io/kueue/kueue@sha256:a559...5a2d` | http=200 from the Mac, index bytes hash to the pin, children: amd64 `6ac15f95...3a11`, arm64 `ddc92259...38d5`, s390x `b4464cc4...190f`, ppc64le `1094b896...490e` |

Chosen path: pull on the Mac by digest (k0), copy with `tsh scp`, then
`kind load image-archive` on the VM (k1). Every blob is checked against the
promoter pin before the image leaves the Mac, and k1 checks the image again on
every node.

---

## Part B1: the Mokka guide vs the DRA driver's ComputeDomain

**Mokka's guide does NOT use the DRA driver's ComputeDomain CRD, controller or
daemons.** It runs its own DaemonSet, with real `nvidia-imex` in NO GPU mode,
started by hand:
- `docs/guides/compute-domain/README.md:19-24` and `:97-117`: Scenario 2
  "renders a per-pod IMEX config, starts the real `nvidia-imex`".
- `run.sh:411-517`: `kubectl exec ... nvidia-imex -c /tmp/imex.cfg`, then
  `-q`/`-N -j` checks and killing a peer.
- The workload is `demo-workload.yaml:9-40` (DaemonSet `compute-domain-demo-workload`,
  nodeSelector `mokka.nvidia.com/type: sgpu`, annotation
  `nvml-mock.nvidia.com/imex-channels: "true"`).
- The upstream path is only described: README `:297-314` ("How the real IMEX fits
  alongside the compute-domain-daemon") and the run.sh summary `:586-591`
  ("can now run unmodified"). The guide does not exercise it.
- The only Mokka artifact that wires the upstream path is the Tilt workflow:
  - `local/compute-domain/dra-driver.values.yaml:18-20` sets
    `resources.computeDomains.enabled: true`;
  - `compute_domain.tiltfile:88-106` builds the `daemon` target of
    `deployments/nvml-mock/Dockerfile.compute-domain-daemon` and pins the DRA
    chart image to it.
- A search for a ComputeDomain object or `computeDomains.enabled=true` in any
  Mokka yaml/sh/go/md/bats file found only that Tilt values file and a comment
  in values.yaml:297. The same search finds `computeDomains.enabled=false` in
  docs/guides/dra.md:73, which serves as the positive control.

What the guide needs on a cluster:
- **containerd NRI** enabled with socket `/var/run/nri/nri.sock`
  (`tests/e2e/kind-compute-domain-config.yaml:25-31`). run.sh refuses to reuse a
  cluster whose `/etc/containerd/config.toml` lacks those lines (`run.sh:81-102`).
- **A topology ConfigMap**: chart `topology.enabled=true` with `topology.domains`
  (`docs/guides/compute-domain/topology.yaml:18-31`; values.yaml:235-248). The
  engine reads it through `NODE_NAME` plus `MOCK_TOPOLOGY_CONFIG` or
  `/config/topology.yaml` (`pkg/gpu/mocknvml/engine/config.go:532-560`).
- **Chart values** `gpu.profile=gb200`, `nri.enabled=true`,
  `imex.mockChannels.enabled=true`, with `channelMajor`/`capsMajor` chosen
  unused on every node (`run.sh:108-132, 346-359`).
- **A demo workload image**, built locally only and never published:
  `docs/guides/compute-domain/Dockerfile:22-41` (ubuntu:22.04 +
  `nvidia-imex-595` from jammy multiverse + `nvidia-imex-shim`, which execs
  `/usr/bin/nvidia-imex.real --nogpu`; `shims/nvidia-imex-shim/main.go:19-57`).
- **IMEX channel devices**: the node agent's IMEX simulator mknods
  `driver/dev/nvidia-caps-imex-channels/channel0..N` with the channel major
  (`internal/agent/imex/stage.go:20-31`), and writes `imex/proc-devices`
  (`:41-55`) and `driver/proc/driver/nvidia/capabilities/fabric-imex-mgmt`
  (`:59-66`). NRI injects them into annotated pods.

**What the upstream DRA path (B-1) needs instead**, from source:
- **Chart settings.**
  - `resources.computeDomains.enabled=true`: the kubelet-plugin DaemonSet gains
    a `compute-domains` container, and a controller Deployment appears
    (`templates/kubeletplugin.yaml:15-17,87-110`, `controller.yaml:15`).
  - `altProcDevices`: `values.yaml:28-34` names `/var/lib/nvml-mock/imex/proc-devices`
    as its example; `kubeletplugin.yaml:153-154,381-384` mount it at
    `/alt-proc-devices` and set `ALT_PROC_DEVICES_PATH`
    (`internal/common/nvcaps.go:32-74`). Without it, the plugin reads the HOST
    `/proc/devices`, which on this VM belongs to the real 595 driver, and
    unmounts `/proc/driver/nvidia` in its container (`cmd/compute-domain-kubelet-plugin/nvlib.go:98-104`).
    My `helm template` confirms that the compute-domains container gets
    `ALT_PROC_DEVICES_PATH=/alt-proc-devices` from hostPath
    `/var/lib/nvml-mock/imex/proc-devices`.
- **IMEX binaries in the daemon image.**
  - The daemon runs `nvidia-imex` and `nvidia-imex-ctl` from PATH
    (`cmd/compute-domain-daemon/main.go:44-50,286,445`).
  - The daemon pods use the controller's own image (`controller.yaml:87-88`
    `IMAGE_NAME`, `daemonset.go:214`; the render shows
    `IMAGE_NAME=<chart image>`), so the chart image must be Mokka's overlay.
  - The daemon does not use NVML: `grep -rln -i nvml cmd/compute-domain-daemon/`
    is empty, while the same grep on the kubelet plugin lists 3 files.
- **Clique ID.**
  - The CD kubelet plugin reads the clique from mock NVML
    `GetGpuFabricInfo` (strict mode, `CrashOnNVLinkFabricErrors` on by
    default, `featuregates.go:166-170`; `nvlib.go:287-357`).
  - It passes the ID to the daemon as CDI env `CLIQUE_ID`
    (`computedomain.go:225-231`).
  - The mock returns the profile's fabric block (`engine/fabric.go:58-103`).
    State `auto` resolves to COMPLETED when `MOCK_FABRICMANAGER_STATE_DIR` is
    unset, as it is in the DRA pod (`fabric_readiness.go:25-33,99-106`).
  - So without any topology overlay the plugin sees:
    - vr200: `00000000-0000-0000-0000-000000000001` / 32766 (vr200.yaml:77-80);
    - gb300: `.../0` (gb300.yaml:55-58);
    - h100: `.../0` (h100.yaml:45-48).
  - This is INFERENCE for the plugin container (not run). c2 prints the plugin's
    own log line "identified fabric clique UUID/ID".
- **IMEX surface.** `<driverRoot>/proc/driver/nvidia/capabilities/fabric-imex-mgmt`
  under altProcDevices (`device_state.go:790-808`), plus the channel nodes. Both
  come from Mokka's `imex.mockChannels` (above).
- **NRI is NOT needed for B-1.** Nothing in the upstream path depends on it; NRI
  only serves Mokka's own demo workload.
- **Upstream precedent.** The DRA driver's own CI runs its GPU and ComputeDomain
  suites against Mokka (`.github/workflows/mock-nvml-e2e.yaml:16,50-52,62-66`,
  checkout `NVIDIA/k8s-test-infra` at 1275802b, profile gb200). It skips every
  test that needs the IMEX daemon: `skip "requires IMEX daemon"` appears in 12
  places across `tests/bats/test_cd_*.bats`. So the upstream CD controller and
  plugin already start on Mokka in CI. What B-1 adds is the real IMEX daemon in
  NO_GPU mode.

## Part B2: what ComputeDomain can prove here, and whether the cluster can be reused

| | Design | What it proves | Theater risk |
|---|---|---|---|
| **B-1 (recommended)** | Upstream CD on worker7..9: ComputeDomain `numNodes: 3`, 3 workload pods (one per VR200 worker), each holding `vr200-x4` + the CD channel claim | The upstream control loop runs end to end on Mokka's VR200 identity: CD, then channel claim prepared, then node labelled `resource.nvidia.com/computeDomain=<uid>`, then a daemon pod per node with `CLIQUE_ID` from mock NVML fabric info, then 3 real IMEX daemons (NO_GPU) forming one domain over the pod network, then CD Ready, then `/dev/nvidia-caps-imex-channels/channel0` in each workload pod. Optional c5: VR200 and GB300 fall into different cliques | **"CD Ready" alone is theater.** With an empty clique ID the daemon starts no IMEX (`main.go:244-250`) and its check is a no-op success (`:436-438`, "check succeeded (noop, clique ID is empty)"). The controller still marks the CD Ready once numNodes daemon pods are Ready (`compute-domain-controller/daemonset.go:385-390`). c4 therefore asserts `CLIQUE_ID` == the expected value, `-q` == READY, `-N -j` UP with 3 READY NO_GPU nodes, the ComputeDomainClique object, the channel's mock major, and peer-loss liveness |
| B-2 | Mokka guide path scoped to the VR200 workers: own DaemonSet, NRI, a topology ConfigMap with one clique for worker7..9, IMEX started by hand | The real IMEX peer protocol in NO_GPU mode, with fabric identity delivered by NRI | It never touches the ComputeDomain API, so presenting it as "ComputeDomain" would be theater. Mokka's NRI plugin also injects the overlay and LD_PRELOAD shims into EVERY container on those nodes outside `mokka` and `kube-system` (`internal/nri/inject/adjust.go:24-63`, `env.go:17-39`, `nri-daemonset.yaml:63`), including the DRA plugin, unless `nri.excludedNamespaces` lists nvidia, kueue-system, local-path-storage and the scenario namespaces |
| B-3 | `resources.computeDomains.imex.mode=hostManaged` (HostManagedIMEXDaemon, Alpha, off; `featuregates.go:187-191`) | Nothing: the controller reports Ready without any daemon (`compute-domain-controller/computedomain.go:277-284`) | Theater by construction. Rejected |

**Smallest meaningful scope:** the 3 real VR200 workers as one NVLink domain.
- No topology ConfigMap is needed. Every VR200 node already reports the same
  fabric identity from its profile (`...0001.32766`).
- A ConfigMap would not reach the DRA plugin anyway without NRI or extra mounts:
  the topology is staged at `/var/lib/nvml-mock/topology/topology.yaml`
  (`internal/nri/inject/config.go:24,129-131`), outside the driver root the
  plugin mounts.

**Reuse the existing cluster. It does not need to be rebuilt.**
- **NRI** is not needed for B-1.
- **If B-2 is ever wanted**, NRI is probably already on:
  - containerd v2.3.1 defaults to `Disable: false`
    (`internal/nri/config.go:47-51`) with socket `/var/run/nri/nri.sock`
    (`vendor/github.com/containerd/nri/pkg/api/plugin.go:27`);
  - kind v0.32.0's `config.toml` has no `nri` section (a grep for "nri" matched
    nothing, while the same file shows its other plugin sections).
  - INFERENCE until checked read-only on the VM:
    `docker exec mokka-hetero-worker7 containerd config dump | grep -A3 'io.containerd.nri.v1.nri'; docker exec mokka-hetero-worker7 ls -la /var/run/nri/nri.sock`.
  - If it turns out to be disabled: edit the node's config and run
    `systemctl restart containerd` INSIDE the node. That is a containerd restart,
    not a node-container restart, so INFERENCE: no /dev re-population and no L4
    re-leak.
  - Side note: Mokka's reuse check greps the file text (`run.sh:81-102`), so it
    would call a default-NRI kind cluster "incompatible" (INFERENCE, not run).
- **B-1 changes, all done in place by helm upgrade:**
  - the three nvml-mock releases (IMEX simulator on);
  - the DRA release: CD on, altProcDevices, and the overlay image. Its
    kubelet-plugin pods restart. INFERENCE: pods started now inherit the
    already-cleaned `/dev` (H1 3b); c2 re-checks `/dev/nvidia*` = 0 on all 10
    nodes.
  - No `s3b-hide-host-gpu.sh --restart` is needed, because no node container
    starts.

## Part B3: drafts and step list (`/tmp/mokka-hetero-58fc971e/h6/cd/`)

| File | What |
|---|---|
| `c1-build-overlay.sh` | Reads the digest of the DRA image that is RUNNING from worker7's CRI and builds Mokka's `Dockerfile.compute-domain-daemon --target daemon` FROM it (the overlay's default base is v0.4.1, `:41`). Gates: `nvidia-imex-ctl -h` runs, the three IMEX files and the four upstream binaries exist, `nvidia-imex.real` loads its libraries on the distroless v0.5.0 base (`deployments/container/Dockerfile:117` `gcr.io/distroless/cc:debug`). Then saves the image and `kind load`s it into all 10 nodes. LOCAL BUILD ONLY |
| `c2-enable-cd.sh` | (a) Picks two majors unused in the HOST `/proc/devices` (240-4095, as run.sh does). (b) `imex.mockChannels` on all 3 nvml-mock releases, then checks on every worker: proc-devices entries, `channel0` major, fabric-imex-mgmt. (c) Helm upgrade of release `nvidia-dra-driver` (H1 s6-dra.sh:9) with CD on, altProcDevices, the overlay image and `pullPolicy=Never`. Then prints each plugin's clique log line and re-checks: no real node has `nvidia.com/gpu.clique` (S3 P2), 48 real GPU devices unchanged, compute-domain slices on 9 workers, `/dev/nvidia*` = 0 |
| `c3-cd-vr200.yaml` | Namespace `mokka-hetero-cd`, `vr200-x4` RCT, ComputeDomain `vr200-cd` (`numNodes: 3`, channel RCT `vr200-cd-channel`), Deployment of 3 replicas with nodeSelector `nvml-mock/profile: vr200`, hostname anti-affinity, and claims `gpus` + `imex-channel` |
| `c4-cd-check.sh` | The readiness checks C1-C6 below |
| `c5-cd-mixed.yaml` | OPTIONAL: one CD with a pod on worker9 (VR200) and one on worker6 (GB300). Expected: two ComputeDomainClique objects (`<uid>.…0001.32766` and `<uid>.…0001.0`), one daemon each |

**Expected readiness evidence (c4):**
- **C1**: 3 Running pods on worker7,8,9, each claim holding 4 `gpu.nvidia.com`
  devices from the pod's own node.
- **C2**: 3 Ready daemon pods in `nvidia` with label
  `resource.nvidia.com/computeDomain=<cd uid>`, each with
  `CLIQUE_ID=00000000-0000-0000-0000-000000000001.32766`.
- **C3**: `nvidia-imex-ctl -c /imexd/imexd.cfg -q` prints exactly `READY` in each
  daemon pod.
- **C4**: `nvidia-imex-ctl -c /imexd/imexd.cfg -N -j` shows `.status == "UP"`
  and 3 nodes READY with version `NO_GPU`. First convergence can take up to
  ~4 min (Mokka README:335-340).
- **C5**:
  - `kubectl -n mokka-hetero-cd get computedomain vr200-cd -o jsonpath='{.status.status}'`
    returns `Ready` (necessary, not sufficient);
  - exactly one ComputeDomainClique `<uid>.00000000-0000-0000-0000-000000000001.32766`
    exists, with daemons worker7/8/9 all Ready;
  - `stat -c '%F %t' /dev/nvidia-caps-imex-channels/channel0` shows
    `character special file <chosen major in hex>` in every workload pod.
- **C6**: deleting the worker9 daemon pod takes worker7's domain out of `UP`;
  the domain returns to `UP` after the DaemonSet replaces the pod.

Offline checks run on the final files:
- The DRA validator (`src/dra-driver-v0.5.0/hack/h6validate`: strict decode into
  the v0.5.0 `resource.nvidia.com/v1beta1` and k8s types) passed on c3 and c5,
  `RESULT fail=0`.
- The mutant `numNode` is caught: `strict decoding error: unknown field "spec.numNode"`.
- `helm template` of the chart 0.5.0 with the c2 settings renders:
  - DaemonSet `dra-driver-nvidia-gpu-kubelet-plugin` with containers
    `compute-domains` (ALT_PROC_DEVICES_PATH=/alt-proc-devices) and `gpus`;
  - Deployment `dra-driver-nvidia-gpu-controller` with
    `IMAGE_NAME=dra-driver-nvidia-gpu-imex-nogpu:v0.5.0-mokka`;
  - 5 DeviceClasses, with `gpu.nvidia.com` -> `nvidia.com/gpu`;
  - no NetworkPolicy (off by default, `values.yaml:272-274,354-356`).
- Two defects in my own drafts, found by that render and fixed:
  - the pod label is `dra-driver-nvidia-gpu-component=kubelet-plugin`, not
    `app.kubernetes.io/component`;
  - the release is `nvidia-dra-driver`, not `dra`.
- `bash -n` and `shellcheck -S warning` pass on c1, c2 and c4.

Step list for Part B on the VM. Run it after H5 frees the real VR200 trays;
Part A and Part B are independent.
1. `bash c1-build-overlay.sh` (needs Docker Hub, nvcr.io, Ubuntu archive and proxy.golang.org).
2. `bash c2-enable-cd.sh`
3. `bash c4-cd-check.sh`
4. Optional: `kubectl apply -f c5-cd-mixed.yaml` and inspect `kubectl -n nvidia get computedomaincliques`.
5. Rollback:
   - `helm rollback nvidia-dra-driver`;
   - `helm upgrade nvml-mock-<r> --reuse-values --set imex.mockChannels.enabled=false` for each release.

## Findings outside the brief (for the chief)

- **F-A1** A Kueue TAS pod set with NO container requests is never admitted.
  It fails the post-nomination fit because an empty request list fits 0 times
  (`pkg/resources/requests.go:227`; probe case c). Any Kueue TAS scenario must
  give its pods at least one request. INFERENCE: likely an upstream bug.
- **F-A2** On this cluster the DRA chart maps `nvidia.com/gpu` to
  `gpu.nvidia.com`, i.e. any GPU type (rendered; the live class is not read). A
  pod that asks for `nvidia.com/gpu` bypasses the per-type CEL selectors. That
  matters if any H5 scenario uses extended resources.
- **F-B1** Mock fidelity: the h100 profile publishes a non-zero fabric cluster
  UUID with clique 0, the same identity as gb300 (h100.yaml:45-48,
  gb300.yaml:55-58). Under the DRA driver, a CD spanning H100 and GB300 workers
  would form ONE IMEX domain (INFERENCE from nvlib.go:287-357). Whether a real
  HGX H100 reports a zero UUID is UNVERIFIED. The driver treats zero as
  "NVLink-capable but not MNNVL" (`nvlib.go:338-341`).
- **F-B2** Two sources of rack identity. KWOK trays take `nvidia.com/gpu.clique`
  from Mokka's SGPURack (`6b0453b6-….0` for VR200). The real nodes' NVML
  fabric info comes from the profile or topology ConfigMap (`…0001.32766`).
  Nothing links them, so a "ComputeDomain inside the VR200 rack" cannot be
  expressed today.
- **F-B3** Doc drift: nvml-mock `values.yaml:299-301` says `altProcDevices` is
  "NOT in any release (absent at v25.12.0)". kubernetes-sigs chart 0.5.0 ships
  it (`values.yaml:28-34`).
- **F-B4** Safety on THIS VM. Mokka keeps a major that the host kernel already
  assigns to the same name (`internal/imex/procdevices.go` validateMajors:
  `owner != m.name`). With a real NVIDIA driver loaded, reusing its
  `nvidia-caps` major would give pods a real device node, so c2 picks majors
  absent from the host's `/proc/devices`. INFERENCE: whether the host's 595
  driver registers `nvidia-caps-imex-channels` at all; c2 prints the host's
  nvidia entries first.

## Risks

1. **Image sources on the VM.**
   - Kueue: the VM cannot pull any Kueue image. H3's gcr.io route does not exist
     for Kueue: `gcr.io/k8s-staging-kueue/kueue` answers 401 with no anonymous
     token, while `gcr.io/k8s-staging-kwok/kwok` answers 200 in the same test.
     Kueue's promoter source is `us-central1-docker.pkg.dev/k8s-staging-images/kueue`
     (`registry.k8s.io/manifests/k8s-staging-kueue/promoter-manifest.yaml:3-4`),
     another *.pkg.dev host. RESOLVED by a host-side pull: k0 has already run on
     the Mac, and the tar goes to the VM with `tsh scp` (63 MB). What's left is
     the scp itself, which needs a valid Teleport session.
   - c1 needs `archive.ubuntu.com` (apt) and proxy.golang.org. The Ubuntu
     archive has not been tested from this VM.
2. **The overlay on the v0.5.0 base is untested.** Mokka built it on v0.4.1.
   The real IMEX binary on distroless/cc (glibc) is INFERENCE; c1 gates it.
3. **Clique from the profile in the DRA plugin container** is INFERENCE (not
   run). If the plugin logs an empty clique, C2-C4 go RED as designed, and the
   CD must not be reported working.
4. **CRD CEL rules** for the Kueue objects are not validated locally (mutant M3
   survived). Step 5 of Part A runs a server dry-run to cover them.
5. **Load on 4 CPUs**:
   - Kueue requests 500m CPU / 512Mi.
   - The CD adds a controller and 3 daemons.
   - The apt + Go build in c1 competes with the cluster. Check `free -m` and
     `uptime` before c1.
6. **Ordering against H5.** Both parts use VR200 devices (A the KWOK rack, B the
   real trays). k7 T0 refuses to start on a non-empty rack. c4 C1 fails if
   another claim holds the real trays.
7. **Teleport expiry (~17:20Z per progress.md).** Both parts together may run
   past it.

## Time estimates (4-CPU VM, happy path / with a debugging budget)

- **Part A: ~25 min / 45-60 min.**
  - image ~3 min, helm ~3, accounting patch ~1, objects ~1;
  - k7 ~10-12, of which T2 is 18 KWOK pods with claims and T4 is admission after
    release.
- **Part B: ~40 min / 90 min.**
  - overlay build 8-15 min, load into 10 nodes 3-5;
  - 3 nvml-mock rollouts plus the DRA upgrade ~10;
  - c4 ~10, IMEX convergence up to 4 min plus liveness up to 5.

## Source-verified vs INFERENCE

Source-verified: each is cited at file:line above, and where marked it was also
run.
- Kueue TAS capacity model, pod-spec demand, zero-fit rule, TAS ignoring DRA,
  gates, annotation names, level-label exclusion, and the required mapping. The
  probe (8 cases) and 2 mutants were run.
- k8s 1.36.1 DRAExtendedResource Beta/on, the fit.go delegation rule, and the
  kubelet capacity/allocatable rule.
- DRA chart 0.5.0 DeviceClass `nvidia.com/gpu` and altProcDevices wiring
  (rendered). The CD daemon empty-clique no-op, the readiness rule, strict clique
  discovery, CLIQUE_ID via CDI, controller image propagation, and feature-gate
  defaults.
- The Mokka guide does not use the upstream CD. Its requirements (NRI, topology,
  values, image, IMEX simulator paths, majors rule), profile fabric values, and
  fabric-state resolution.
- containerd 2.3.1 NRI default enabled with socket `/var/run/nri/nri.sock`. kind
  0.32.0's config has no nri section.
- Kueue Helm render with my values: webhook scope and failurePolicy, with the
  chart defaults as positive control. Kueue config validation.
- Upstream DRA CI runs Mokka and skips IMEX-daemon tests.

INFERENCE (not run on the cluster):
- The live DeviceClass carries `nvidia.com/gpu`.
- NRI is already enabled on the kind nodes.
- The DRA CD plugin derives `…0001.32766` for VR200 without a topology overlay.
- The overlay runs on the v0.5.0 distroless base.
- A containerd restart does not re-leak the L4.
- The H100 fidelity note (F-B1).
- The empty-request quirk is unintended upstream (F-A1).
- Whether the host driver registers an IMEX channel major (F-B4).
- Every expected cluster output of k2/k3/k7/c2/c4 beyond what the probe
  reproduces.

Scratch code (not a deliverable, never committed):
- Probe: `/tmp/mokka-hetero-58fc971e/h6/src/kueue/pkg/scheduler/zz_h6_probe_test.go`
  (== the draft copy, per cmp).
- Validators: `/tmp/mokka-hetero-58fc971e/h6/src/kueue/hack/h6validate/` and
  `/tmp/mokka-hetero-58fc971e/h6/src/dra-driver-v0.5.0/hack/h6validate/`.
