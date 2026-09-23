# Task H5 report: scheduling scenarios S1-S3 and the D3 mutation

Status: DONE_WITH_CONCERNS (2026-09-23 13:53Z to 15:52Z). S1, S2 and S3 pass
(42/42 twice, the second time after D3, rc=0). Every scenario and every
assertion is mutation-verified. D3 went RED and then back to GREEN. The
concerns are findings F1-F3 at the end. None of them blocks a result.

VM work lives under `~/mokka-hetero/h5/` (scripts, manifests, mutants), logs
under `~/mokka-hetero/logs/h5-*`, dumps under `~/mokka-hetero/out/h5/<run>/`.
Local copies (byte-identical to the VM's, `cmp` on all 13 scripts):
`/tmp/mokka-hetero-58fc971e/h5/scripts/` (authoring copies),
`/tmp/mokka-hetero-58fc971e/h5/{h5,logs,out}/` (tarball copied back from the VM).

| Step | State |
|---|---|
| 0 start state | DONE, all PASS (rc=0) |
| 1 manifests + checker | DONE (`h5/check-scenarios.sh`) |
| S1 type targeting (+ S1b naive) | PASS 16/16; S1b mixes 2-5 of 12 onto GB300 |
| S2 no spill | PASS 8/8 |
| S3 rack locality | PASS 10/10 |
| mutation verification | live: 3/3 scenario mutants KILLED; dumps: 24/24 assertion mutants KILLED |
| D3 relabel, RED, revert, GREEN | DONE: RED (Rubin 80 / Blackwell 88), GREEN after revert |
| final run after D3 + end state | 42 PASS / 0 FAIL, rc=0; end state = start state (rc=0) |

## Step 0: start state (`h5/h5-s0-start.sh`, log `logs/h5-s0-start.log`)

Exits non-zero if anything the brief lists does not hold.

```
$ bash ~/mokka-hetero/h5/h5-s0-start.sh; echo "s0 rc=$?"
start 2026-09-23T14:01:03Z context=kind-mokka-hetero
PASS readyz = ok
PASS nodes total = 64
PASS nodes Ready = 64
PASS real nodes (no type label) = 10
PASS kwok nodes (type=kwok) = 54
mokka-hetero-worker{,2,3} profile=h100 / worker4-6 gb300 / worker7-9 vr200, all clique=-
PASS real nodes with a clique label = 0
     18 gb300 34a5a1db-6cd8-5f1f-ac99-737c1ac575e1.0
     18 h100 618cfd92-1ae5-560d-8b55-8d8865e2d28b.0
     18 vr200 6b0453b6-5432-5c2d-a9b4-f8aa9a7b5739.0
PASS distinct (gpu-type, clique) pairs on kwok nodes, each x18 = 3
PASS distinct clique values = 3
PASS sgpuracks = 3
PASS gpu.nvidia.com devices = 336
PASS arch counts = Blackwell=84 Hopper=168 Rubin=84
PASS kwok stages = node-heartbeat-with-lease node-initialize pod-delete pod-ready
PASS resourceclaims anywhere = 0        (detect-vllm holds only H4's 3 templates)
kind node containers: restarts 0, started 2026-09-23T10:10:57Z, dev-nvidia=0 on all 10
pods not Running/Completed: (none)
busybox on nodes: none; registry.k8s.io/pause:3.10 on all 10
Mem: total 15363 used 4874 available 10488
DONE fail=0 2026-09-23T14:01:07Z
s0 rc=0
```

## Step 1: manifests and checker

### Manifests (`h5/gen-manifests.sh` -> `h5/manifests/`)

Derived from H2's drafts (VM copies byte-identical to local: same sha256 for
`dra/claim-templates.yaml` and all 5 scenario files). Only mechanical changes,
each shown by the generator's diff:
- namespace `mokka-hetero-sched` -> `sched-test`;
- image `busybox:1.36` -> `registry.k8s.io/pause:3.10` + `imagePullPolicy: IfNotPresent`,
  and the `command:` line dropped. busybox is on no node (step 0), and the brief
  prefers node-local images. pause does nothing with the injected device nodes
  (H4 F1: a claim on a real node injects the L4's major/minor);
- two NAIVE templates added for S1b only: `vr200-naive-mem`
  (`device.capacity['gpu.nvidia.com'].memory.compareTo(quantity('288Gi')) == 0`)
  and `vr200-naive-cc10` (`cudaComputeCapability.major() == 10`), the same
  expressions as H2's celprobe (`celprobe/main.go:74,76`);
- `s1b.yaml`: the s1-vr200 Deployment renamed, 12 replicas, once per naive template.

First generation had one bug, caught before use: the Pod in `s2-extra.yaml` got
an 8-space `imagePullPolicy` under a 4-space container. Fixed by reusing the
matched indentation; all six scenario files then pass `kubectl apply --dry-run=server` (rc=0 each).

Smoke test (`h5/h5-smoke.sh`): one pause pod with a vr200-x1 claim pinned to a
real VR200 worker and one pinned to a KWOK tray. Both Running within 4s; the
real one was prepared by the DRA plugin and started by containerd; the claim
is owned by the Pod and `pod.status.resourceClaimStatuses` is set on both tiers:

```
t+4s smoke-kwok-vr200-00=Running smoke-mokka-hetero-worker8=Running
{"name":"smoke-kwok-vr200-00-gpu-92td8","owner":[{"kind":"Pod","name":"smoke-kwok-vr200-00"}],"results":[{"device":"gpu-2","driver":"gpu.nvidia.com","pool":"kwok-vr200-00","request":"gpu"}],"reservedFor":["smoke-kwok-vr200-00"]}
{"name":"smoke-mokka-hetero-worker8-gpu-xvlpf","owner":[{"kind":"Pod","name":"smoke-mokka-hetero-worker8"}],"results":[{"device":"gpu-2","driver":"gpu.nvidia.com","pool":"mokka-hetero-worker8","request":"gpu"}],"reservedFor":["smoke-mokka-hetero-worker8"]}
Normal Pulled pod/smoke-mokka-hetero-worker8 Container image "registry.k8s.io/pause:3.10" already present on machine
cleanup done after ~2s: pods=0 claims=0
```

### Checker design (`h5/check-scenarios.sh` + `h5lib.jq`, `assert-s1.jq`, `report-s1b.jq`, `assert-s2.jq`, `assert-s3.jq`)

- The driver runs S1, S1b, S2 and S3 in order. Before each one it asserts
  that sched-test has 0 pods and the cluster has 0 ResourceClaims. After each
  one it deletes everything and asserts that 0 pods and 0 claims remain.
- After each scenario it dumps pods, all ResourceClaims, ResourceSlices,
  Nodes, SGPURacks and sched-test events into one JSON file, then runs that
  scenario's jq program over it. The assertions read only the dump, so the same
  programs can be run again on edited copies of a dump (the dump mutants below).
- Two independent sources per pod: device identity comes from the claim's
  allocation results, looked up as `pool/device` in the ResourceSlices. Node
  type comes from node labels (`nvml-mock/profile` on real nodes,
  `mokka-hetero.nvidia.com/gpu-type` on KWOK nodes). The expected values are
  fixed constants in `h5lib.jq` (H1's step 7 table).
- Events are matched on the pod UID, so events left over from an earlier run
  (same pod name, e.g. `s2-vr200-extra`) cannot satisfy a check.
- The driver counts a FAIL when an assertion program exits non-zero, or when it
  prints a different number of check lines than expected (S1 16, S2 8, S3 10).
  Before the first cluster run, all four programs were run on an empty dump:
  every check printed FAIL (none passes vacuously), and the line counts were
  16/0/8/10. The first compile failed (`label` is a jq keyword). The rc
  guard would have caught that.
- Wall-clock: the driver prints apply -> all bound -> all Running. The jq
  programs print the server-side latency from each pod's creationTimestamp to
  its PodScheduled condition.

## Step 2: green run of the checker (run `green1`, 14:54:10Z to 14:55:25Z)

`H5_RUN=green1 bash ~/mokka-hetero/h5/check-scenarios.sh` (under nohup; log
`logs/h5-check-green1.log`, copied back to `/tmp/mokka-hetero-58fc971e/h5/logs/`).
Summary line `SUMMARY run=green1 pass=42 fail=0`. The nohup wrapper did not
record the exit code; the final run after D3 (below) records it.
Verbatim, trimmed to the decisive lines:

```
14:54:11Z ===== s1
PASS S1 precondition: sched-test has 0 pods, cluster has 0 ResourceClaims
14:54:12Z TIME S1 bound: 12/12 bound after 1.5s (since apply)
14:54:12Z TIME S1 running: 12/12 running after 1.6s (since apply)
PASS S1 h100: 4 pods, all bound and Running
PASS S1 h100: 4 allocated claims, exactly 1 gpu.nvidia.com device each
PASS S1 h100: every allocated device is Hopper | NVIDIA H100 80GB HBM3 | 9.0.0 in its ResourceSlice
PASS S1 h100: every pod's node is a h100 node (node labels)
PASS S1 h100: every allocated device is on its pod's node
PASS S1 gb300: (the same 5 checks, Blackwell | NVIDIA GB300 NVL | 10.0.0)
PASS S1 vr200: (the same 5 checks, Rubin | NVIDIA Graphics Device | 10.7.0)
PASS S1: 12 devices allocated in sched-test, none twice
INFO S1 placement by tier: kwok=12; by node type: gb300=4 h100=4 vr200=4
TIMING S1 all 12 pods: scheduled=12 per-pod create->scheduled min=0s max=0s; first create -> last scheduled=0s
PASS S1 cleanup: 0 pods and 0 claims in sched-test after 2.5s
14:54:15Z TIME s1 total (apply to cleaned up): 4.7s
14:54:15Z ===== s1b
REPORT S1b vr200-naive-mem: pods=12 bound=12 allocated=12
REPORT S1b vr200-naive-mem: allocated devices by architecture: Blackwell=3 Rubin=9
REPORT S1b vr200-naive-mem: pods by node type: gb300=3 vr200=9; by tier: kwok=12
REPORT S1b vr200-naive-cc10: pods=12 bound=12 allocated=12
REPORT S1b vr200-naive-cc10: allocated devices by architecture: Blackwell=2 Rubin=10
REPORT S1b vr200-naive-cc10: pods by node type: gb300=2 vr200=10; by tier: kwok=12
PASS S1b cleanup: 0 pods and 0 claims in sched-test after 2.6s
14:54:21Z ===== s2
PASS S2 precondition: sched-test has 0 pods, cluster has 0 ResourceClaims
14:54:29Z TIME S2 fill bound: 84/84 bound after 8.4s (since apply)
14:54:29Z TIME S2 fill running: 84/84 running after 8.6s (since apply)
14:54:30Z EVENTWAIT S2 extra: 1 FailedScheduling event(s) after 1s
14:54:50Z S2 extra observed for 20.3s
PASS S2 precondition: the cluster publishes exactly 84 Rubin devices
PASS S2 fill: 84 pods, all bound and Running
PASS S2 fill: 84 allocated claims, 1 device each, together exactly the cluster's 84 Rubin devices
PASS S2 extra: exactly one extra pod, Pending and unbound
PASS S2 extra: its claim exists and has no allocation
PASS S2 extra: the scheduler recorded FailedScheduling for this pod (uid)
PASS S2: zero non-Rubin (so zero Blackwell) devices allocated to any sched-test claim
PASS S2: all 84 Blackwell devices stayed free cluster-wide (GB300 capacity was there to spill into)
EVENT S2 extra FailedScheduling count=1 message: 0/64 nodes are available: 1 node(s) had untolerated taint(s), 63 cannot allocate all claims. still not schedulable, preemption: 0/64 nodes are available: 64 Preemption is not helpful for scheduling.
INFO S2 fill placement by tier: kwok=72 real=12; by node type: vr200=84; nodes used: 21
TIMING S2 fill 84 pods: scheduled=84 per-pod create->scheduled min=0s max=5s; first create -> last scheduled=7s
PASS S2 cleanup: 0 pods and 0 claims in sched-test after 8.7s
14:54:59Z TIME s2 total (apply to cleaned up): 38.5s
14:54:59Z ===== s3
PASS S3 precondition: sched-test has 0 pods, cluster has 0 ResourceClaims
14:55:01Z TIME S3 A bound: 18/18 bound after 1.6s (since apply)
14:55:01Z TIME S3 A running: 18/18 running after 1.7s (since apply)
14:55:02Z EVENTWAIT S3 B: 5 FailedScheduling event(s) after 1s
14:55:22Z S3 B observed for 20.6s
PASS S3 A: 18 pods, all bound and Running
PASS S3 A: 18 distinct nodes (one whole tray per pod)
PASS S3 A: every A node carries nvidia.com/gpu.clique and all share ONE value
PASS S3 A: that value is the vr200 SGPURack's fabricUUID.cliqueID
PASS S3 A: no A pod on a real (non-KWOK) node
PASS S3 A: every claim holds 4 Rubin devices, all on its pod's node
PASS S3 B: 18 pods, none bound, all Pending
PASS S3 B: no B claim allocated
PASS S3 B: the scheduler recorded FailedScheduling for B pods (uid)
PASS S3 B: the 12 real VR200 devices (no clique) stayed free, so B was held by the affinity, not by capacity
EVENT S3 B (latest of 18) s3-rack-b-9-8h6wt count=1 message: 0/64 nodes are available: 1 node(s) had untolerated taint(s), 54 cannot allocate all claims, 9 node(s) didn't match pod affinity rules. still not schedulable, preemption: 0/64 nodes are available: 64 Preemption is not helpful for scheduling.
INFO S3 B pods by phase: Pending=18; bound: 0
TIMING S3 A 18 pods: scheduled=18 per-pod create->scheduled min=0s max=0s; first create -> last scheduled=0s
PASS S3 cleanup: 0 pods and 0 claims in sched-test after 3.0s
14:55:25Z TIME s3 total (apply to cleaned up): 26.1s
14:55:25Z SUMMARY run=green1 pass=42 fail=0
```

### S3 placement table (Job A, run green1)

All 18 pods are on distinct KWOK VR200 trays, all in clique
`6b0453b6-5432-5c2d-a9b4-f8aa9a7b5739.0`, and each pod holds its tray's 4 Rubin
devices:

| idx | node | idx | node | idx | node |
|---|---|---|---|---|---|
| 0 | kwok-vr200-00 | 6 | kwok-vr200-03 | 12 | kwok-vr200-09 |
| 1 | kwok-vr200-02 | 7 | kwok-vr200-11 | 13 | kwok-vr200-10 |
| 2 | kwok-vr200-01 | 8 | kwok-vr200-08 | 14 | kwok-vr200-05 |
| 3 | kwok-vr200-06 | 9 | kwok-vr200-12 | 15 | kwok-vr200-14 |
| 4 | kwok-vr200-04 | 10 | kwok-vr200-13 | 16 | kwok-vr200-17 |
| 5 | kwok-vr200-16 | 11 | kwok-vr200-07 | 17 | kwok-vr200-15 |

(`ROW S3A idx=0 s3-rack-a-0-5dtjz node=kwok-vr200-00 tier=kwok clique=6b0453b6-5432-5c2d-a9b4-f8aa9a7b5739.0 devices=gpu-2(Rubin),gpu-0(Rubin),gpu-3(Rubin),gpu-1(Rubin)`,
the same shape for all 18 rows; full rows in the log.)

### Reading the results

- S1: all 12 pods landed on KWOK nodes (4 per type), each on a device of its
  own type. INFERENCE: NodeResourcesFit scoring prefers the fake 64-CPU nodes
  over the 4-CPU real workers. S1 therefore did not exercise real-node
  placement; S2 did (12 real + 72 KWOK).
- S1b (the trap): the naive memory selector put 3 of 12 "VR200" pods on
  GB300, and the naive CC-major-10 selector put 2 of 12 there. With 12 pods the
  mix is scoring-dependent, not a fixed ratio. The MS2 mutant below (84 pods on
  the naive CC selector) gave 42 GB300 + 42 VR200.
- S2: the 85th VR200 claim stayed unallocated while all 84 Blackwell devices
  were free. The message counts 63 nodes that "cannot allocate all claims": the
  63 GPU nodes (the 21 H100 and 21 GB300 nodes plus the 21 full VR200 nodes).
- S3: B's message separates the two filters: 9 nodes "didn't match pod
  affinity rules" (the 9 real workers carry no clique, including the 3 real
  VR200 workers whose 12 Rubin devices were free), and 54 "cannot allocate all
  claims" (the 18 full VR200 trays plus the 36 GB300/H100 rack nodes, which have
  cliques but no Rubin device).
- Scheduler latency at 64 nodes / 336 devices: at most 5s from pod creation to
  PodScheduled (S2's 84 pods, 7s from the first creation to the last bind);
  S1/S3 all within the same second. Cleanup (pods deleted, claims gone) took
  2.5-8.7s.

## Step 3: mutation verification

### 3a. Live: one manifest mutant per scenario (`h5/mutate-live.sh`, log `logs/h5-mutate-live.log`)

Each mutant is a copy of `manifests/` with one deliberate change. The
unchanged checker runs it with `H5_MANIFESTS=<mutant> H5_ONLY=<scenario>`. A
mutant counts as KILLED only if the checker exits non-zero AND prints the named
target FAIL line. The script prints the full `diff -ru` of every mutant (1, 2
and 2 changed files; each diff touches only the intended lines):

```
MS1 s1.yaml        -        resourceClaimTemplateName: vr200-x1   +  resourceClaimTemplateName: gb300-x1   (the s1-vr200 Deployment only)
MS2 s2-fill.yaml, s2-extra.yaml   vr200-x1 -> vr200-naive-cc10    (a "VR200" selector that also admits GB300)
MS3 s3-a.yaml, s3-b.yaml   requiredDuringSchedulingIgnoredDuringExecution: [{labelSelector, topologyKey}]
                        -> preferredDuringSchedulingIgnoredDuringExecution: [{weight: 100, podAffinityTerm: {same labelSelector, same topologyKey}}]
```

Runs (verbatim, trimmed to the FAIL lines):

```
== RUN ms1 (H5_ONLY=s1)
FAIL S1 vr200: every allocated device is Rubin | NVIDIA Graphics Device | 10.7.0 in its ResourceSlice :: "devices=4 wrong=[\"kwok-gb300-05/gpu-0=Blackwell|NVIDIA GB300 NVL|10.0.0\",\"kwok-gb300-17/gpu-1=Blackwell|NVIDIA GB300 NVL|10.0.0\",\"kwok-gb300-04/gpu-1=Blackwell|NVIDIA GB300 NVL|10.0.0\",\"kwok-gb300-03/gpu-1=Blackwell|NVIDIA GB300 NVL|10.0.0\"]"
FAIL S1 vr200: every pod's node is a vr200 node (node labels) :: ["s1-vr200-cc594f854-nxhqb on kwok-gb300-05 type=gb300", ... 4 pods]
15:02:36Z SUMMARY run=mut-ms1 pass=16 fail=2
KILLED ms1: checker rc=1, target line present: FAIL S1 vr200: every allocated device is Rubin
== RUN ms2 (H5_ONLY=s2)
15:04:17Z TIME S2 extra bound: 1/1 bound after 91.2s (since apply)      (no FailedScheduling within 90s; it was bound)
FAIL S2 fill: 84 allocated claims, 1 device each, together exactly the cluster's 84 Rubin devices :: "claims=84 devices=84 arch=Blackwell=42 Rubin=42 rubin-not-held=[...]"
FAIL S2 extra: exactly one extra pod, Pending and unbound :: ["s2-vr200-extra node=kwok-vr200-02 phase=Running"]
FAIL S2 extra: its claim exists and has no allocation :: [... allocated=true devs=[\"kwok-vr200-02/gpu-3(Rubin)\"]]
FAIL S2 extra: the scheduler recorded FailedScheduling for this pod (uid) :: "events=0"
FAIL S2: zero non-Rubin (so zero Blackwell) devices allocated to any sched-test claim :: "allocated=85 by arch: Blackwell=42 Rubin=43"
FAIL S2: all 84 Blackwell devices stayed free cluster-wide (GB300 capacity was there to spill into) :: "blackwell=84 allocated=42"
INFO S2 fill placement by tier: kwok=72 real=12; by node type: gb300=42 vr200=42; nodes used: 42
15:04:47Z SUMMARY run=mut-ms2 pass=4 fail=6
KILLED ms2: checker rc=1, target line present: FAIL S2: zero non-Rubin (so zero Blackwell) devices allocated
== RUN ms3 (H5_ONLY=s3)
PASS S3 A: (all 6 A checks pass: preferred affinity plus scoring still packs A into the rack)
FAIL S3 B: 18 pods, none bound, all Pending :: "pods=18 bound=[\"s3-rack-b-0-jhpmd node=mokka-hetero-worker8 tier=real clique=null\",\"s3-rack-b-1-pnqkj node=mokka-hetero-worker7 tier=real clique=null\",\"s3-rack-b-2-twkqz node=mokka-hetero-worker9 tier=real clique=null\"]"
FAIL S3 B: no B claim allocated :: [... worker8 gpu-2,0,3,1 / worker7 gpu-0,3,1,2 / worker9 ...]
FAIL S3 B: the 12 real VR200 devices (no clique) stayed free, so B was held by the affinity, not by capacity :: "real rubin=12 allocated=[... 12 devices on worker7/8/9]"
EVENT S3 B (latest of 15) ... message: 0/64 nodes are available: 1 node(s) had untolerated taint(s), 63 cannot allocate all claims. ...
INFO S3 B pods by phase: Pending=15 Running=3; bound: 3
15:05:14Z SUMMARY run=mut-ms3 pass=9 fail=3
KILLED ms3: checker rc=1, target line present: FAIL S3 B: 18 pods, none bound, all Pending
after mutants: sched-test pods=0 cluster claims=0
DONE survived=0 2026-09-23T15:05:15Z
MUTATE_LIVE_RC=0
```

MS3 shows the failure mode S3 guards against. With preferred affinity, B
splits: its first 3 pods take the clique-less real VR200 workers 7/8/9, and the
FailedScheduling message loses its "didn't match pod affinity rules" part. With
required affinity (green) those 9 nodes are rejected by the affinity filter.

### 3b. Per assertion: dump mutants (`h5/mutate-dumps.sh green1`, log `logs/h5-mutate-dumps-green1.log`)

The live mutants leave several assertions untouched (for example every S3 A
check under MS3). So each assertion also gets a mutant: one fact changed in a
copy of green1's dump, then the unchanged jq program runs on it. The cluster is
not touched. The "leaf lines changed" count shows how wide each mutant is.

```
== baseline s1: rc=0 PASS=16 FAIL=0
== baseline s2: rc=0 PASS=8 FAIL=0
== baseline s3: rc=0 PASS=10 FAIL=0
KILLED m1a (s1, 2 leaf lines changed, 1 FAIL): FAIL S1 vr200: 4 pods, all bound and Running :: [... phase=Pending ...]
KILLED m1b (s1, 2 leaf lines changed, 1 FAIL): FAIL S1 h100: 4 allocated claims, exactly 1 gpu.nvidia.com device each
KILLED m1c (s1, 2 leaf lines changed, 1 FAIL): FAIL S1 vr200: every allocated device is Rubin | ... :: "devices=4 wrong=[\"kwok-vr200-01/gpu-2=Blackwell|NVIDIA Graphics Device|10.7.0\"]"
KILLED m1d (s1, 2 leaf lines changed, 1 FAIL): FAIL S1 vr200: every pod's node is a vr200 node (node labels) :: ["s1-vr200-7df6f8c67d-7smlw on kwok-vr200-01 type=gb300"]
KILLED m1e (s1, 2 leaf lines changed, 1 FAIL): FAIL S1 gb300: every allocated device is on its pod's node :: ["s1-gb300-69dd6bb5bb-4xq75 node=kwok-gb300-00 devs=[\"kwok-gb300-06/gpu-0\"]"]
KILLED m1f (s1, 4 leaf lines changed, 1 FAIL): FAIL S1: 12 devices allocated in sched-test, none twice :: "allocated=12 distinct=11"
KILLED m2a (s2, 11 leaf lines changed, 2 FAIL): FAIL S2 precondition: ... exactly 84 Rubin devices :: "rubin=85" | FAIL S2 fill: ... together exactly the cluster's 84 Rubin devices :: "... rubin-not-held=[\"kwok-vr200-00/gpu-99\"]"
KILLED m2b (s2, 2 leaf lines changed, 1 FAIL): FAIL S2 fill: 84 pods, all bound and Running
KILLED m2c (s2, 2 leaf lines changed, 1 FAIL): FAIL S2 fill: 84 allocated claims, ... together exactly the cluster's 84 Rubin devices :: "... rubin-not-held=[\"kwok-vr200-08/gpu-2\"]"
KILLED m2d (s2, 3 leaf lines changed, 1 FAIL): FAIL S2 extra: exactly one extra pod, Pending and unbound :: ["s2-vr200-extra node=kwok-gb300-00 phase=Running"]
KILLED m2e (s2, 4 leaf lines changed, 1 FAIL): FAIL S2 extra: its claim exists and has no allocation
KILLED m2f (s2, 2 leaf lines changed, 1 FAIL): FAIL S2 extra: the scheduler recorded FailedScheduling for this pod (uid) :: "events=0"
KILLED m2g (s2, 4 leaf lines changed, 2 FAIL): FAIL S2 extra: its claim exists and has no allocation | FAIL S2: zero non-Rubin ... :: "allocated=85 by arch: Hopper=1 Rubin=84"
KILLED m2h (s2, 6 leaf lines changed, 1 FAIL): FAIL S2: all 84 Blackwell devices stayed free cluster-wide ... :: "blackwell=84 allocated=1"
KILLED m3a (s3, 2 leaf lines changed, 1 FAIL): FAIL S3 A: 18 pods, all bound and Running
KILLED m3b (s3, 10 leaf lines changed, 1 FAIL): FAIL S3 A: 18 distinct nodes (one whole tray per pod) :: "distinct nodes=17"
KILLED m3c (s3, 2 leaf lines changed, 2 FAIL): FAIL S3 A: ... share ONE value :: "clique values=34a5a1db-...75e1.0=1 6b0453b6-...5739.0=17" | FAIL S3 A: that value is the vr200 SGPURack's ...
KILLED m3d (s3, 2 leaf lines changed, 1 FAIL): FAIL S3 A: that value is the vr200 SGPURack's fabricUUID.cliqueID :: "A=[\"6b0453b6-...5739.0\"] vr200-rack=[\"00000000-0000-0000-0000-000000000000.0\"]"
KILLED m3e (s3, 1 leaf lines changed, 1 FAIL): FAIL S3 A: no A pod on a real (non-KWOK) node :: ["s3-rack-a-0-5dtjz on kwok-vr200-00 tier=real"]
KILLED m3f (s3, 4 leaf lines changed, 1 FAIL): FAIL S3 A: every claim holds 4 Rubin devices, all on its pod's node
KILLED m3g (s3, 1 leaf lines changed, 1 FAIL): FAIL S3 B: 18 pods, none bound, all Pending
KILLED m3h (s3, 4 leaf lines changed, 1 FAIL): FAIL S3 B: no B claim allocated
KILLED m3i (s3, 40 leaf lines changed, 1 FAIL): FAIL S3 B: the scheduler recorded FailedScheduling for B pods (uid) :: "events=0"
KILLED m3j (s3, 6 leaf lines changed, 1 FAIL): FAIL S3 B: the 12 real VR200 devices (no clique) stayed free ... :: "real rubin=12 allocated=[\"mokka-hetero-worker7/gpu-0\"]"
DONE bad=0 2026-09-23T15:15:39Z
mutate-dumps rc=0
```

Mutants: m1a/m2b/m3a set one pod Pending. m1b sets a result's driver to another
name. m1c changes the architecture of the slice device held by one pod. m1d
changes a node's type label. m1e moves a pod to a free node of the same type.
m1f points two claims at one device. m2a adds an 85th Rubin device. m2c
duplicates one fill claim's device. m2d binds the extra pod. m2e/m2g/m3h give an
unallocated claim a Rubin/Hopper/Rubin device. m2f/m3i swap event UIDs for a
stale one (this proves the UID match). m2h/m3j add a claim in another namespace
holding a Blackwell / real-VR200 device. m3b moves one A pod and its claim onto
another A pod's tray. m3c gives one A node the GB300 clique. m3d changes the
rack's fabricUUID. m3e drops `type=kwok` from one A node. m3f cuts one A claim
to 3 devices. m3g binds one B pod.

21 of 24 mutants turn only their target line red. The three that turn two
lines red do so because the second assertion depends on the same fact: m2a
(the fill must equal the Rubin set), m2g (the extra claim is now allocated),
m3c (a second clique value is also not the rack's).
m3i changes 40 leaf lines because it rewrites the UID of every FailedScheduling event.

## Step 4: D3 detection mutation (`h5/h5-d3.sh pre|flip|revert` + `h5/check-identity.sh`)

`check-identity.sh` is the fixed-expectation identity check. Its constants:
cluster-wide tuple counts Hopper 168 / Blackwell 84 / Rubin 84, no other tuple,
and each real worker checked against a fixed type map (worker..3 h100 x8,
4-6 gb300 x4, 7-9 vr200 x4). It reads no node labels.

Deviation (deliberate): the relabel is done in two steps. First
`nvml-mock/profile-`, then wait until no nvml-mock pod is left on worker9, then
set `=gb300`. The reason: node-agent runs `Revoke -> Discard` when it stops
(`internal/agent/agent.go:104-109` at de8a00dd), and Discard deletes
`driver/dev`, `driver/usr/lib64`, `config/config.yaml` and more under the
shared `/var/lib/nvml-mock` hostPath (`internal/agent/gpudriver/gpudriver.go:75-110`).
INFERENCE, not reproduced: in a one-step relabel the vr200 pod's teardown
could delete files the new gb300 pod has just staged. After the relabel, the
DRA kubelet-plugin pod on worker9 is deleted, and its DaemonSet recreates it.

### pre (log `logs/h5-d3-pre.log`), GREEN

```
-- 15:40:02Z state: label nvml-mock/profile=vr200
   mock pods on mokka-hetero-worker9: nvml-mock-vr200 nvml-mock-vr200-xd7td phase=Running ready=True deleting=false
   plugin pod: dra-driver-nvidia-gpu-kubelet-plugin-z62sk phase=Running ready=True deleting=false
   slice: 00000-gpu.nvidia.com-mokka-hetero-worker9-j5krf poolgen=1 devices=4 4x NVIDIA Graphics Device|Rubin|10.7.0|drv 615.23.0
84 NVIDIA GB300 NVL|Blackwell|10.0.0
84 NVIDIA Graphics Device|Rubin|10.7.0
168 NVIDIA H100 80GB HBM3|Hopper|9.0.0
PASS identity counts are exactly Hopper 168 / Blackwell 84 / Rubin 84
PASS mokka-hetero-worker9 fixed=vr200: 4 NVIDIA Graphics Device|Rubin|10.7.0     (and the 8 other workers PASS)
IDENTITY fail=0
D3 pre: identity check rc=0 (want 0)
```

### flip vr200 -> gb300 (log `logs/h5-d3-flip.log`), RED

```
15:40:16Z step 1: kubectl label node mokka-hetero-worker9 nvml-mock/profile- (was vr200)
15:40:19Z wait_mock none: reached after 3s
15:40:19Z step 2: kubectl label node mokka-hetero-worker9 nvml-mock/profile=gb300
15:40:31Z wait_mock nvml-mock-gb300: reached after 12s nvml-mock-gb300 nvml-mock-gb300-55j9b phase=Running ready=True deleting=false
{"level":"info","time":"2026-09-23T15:40:20.625Z","msg":"simulator staged","simulator":"gpudriver"}
15:40:32Z deleting plugin pod dra-driver-nvidia-gpu-kubelet-plugin-z62sk
15:40:35Z new plugin pod ready after 2s: dra-driver-nvidia-gpu-kubelet-plugin-tzwsz phase=Running ready=True deleting=false
15:40:39Z worker9 slice is [4 NVIDIA GB300 NVL|Blackwell|10.0.0] after 4s
   slice: 00000-gpu.nvidia.com-mokka-hetero-worker9-j5krf poolgen=1 devices=4 4x NVIDIA GB300 NVL|Blackwell|10.0.0|drv 570.124.6
== identity tuples over all gpu.nvidia.com devices (count tuple)
88 NVIDIA GB300 NVL|Blackwell|10.0.0
80 NVIDIA Graphics Device|Rubin|10.7.0
168 NVIDIA H100 80GB HBM3|Hopper|9.0.0
FAIL identity counts differ from Hopper 168 / Blackwell 84 / Rubin 84
FAIL mokka-hetero-worker9 fixed=vr200: got [4 NVIDIA GB300 NVL|Blackwell|10.0.0] want [4 NVIDIA Graphics Device|Rubin|10.7.0]
IDENTITY fail=1
D3 flip: identity check rc=1 (want non-zero)
D3_FLIP_RC=0
```

Rubin dropped to 80 and Blackwell rose to 88, as the brief predicts. The
plugin rewrote the existing slice in place: same name, `poolgen=1` before and
after.

### revert gb300 -> vr200 (log `logs/h5-d3-revert.log`), GREEN

```
15:41:09Z step 1: kubectl label node mokka-hetero-worker9 nvml-mock/profile- (was gb300)
15:41:11Z wait_mock none: reached after 2s
15:41:11Z step 2: kubectl label node mokka-hetero-worker9 nvml-mock/profile=vr200
15:41:24Z wait_mock nvml-mock-vr200: reached after 13s nvml-mock-vr200 nvml-mock-vr200-t7d2l phase=Running ready=True deleting=false
15:41:29Z new plugin pod ready after 4s: dra-driver-nvidia-gpu-kubelet-plugin-77t48 phase=Running ready=True deleting=false
15:41:30Z worker9 slice is [4 NVIDIA Graphics Device|Rubin|10.7.0] after 1s
   slice: 00000-gpu.nvidia.com-mokka-hetero-worker9-j5krf poolgen=1 devices=4 4x NVIDIA Graphics Device|Rubin|10.7.0|drv 615.23.0
worker9 devices pre vs revert: diff rc=1 (want 0)          <- order only, see below
kind node containers pre vs revert (restarts, startedAt, dev-nvidia): diff rc=0 (want 0; else run scripts/s3b-hide-host-gpu.sh --restart)
84 NVIDIA GB300 NVL|Blackwell|10.0.0
84 NVIDIA Graphics Device|Rubin|10.7.0
168 NVIDIA H100 80GB HBM3|Hopper|9.0.0
PASS identity counts are exactly Hopper 168 / Blackwell 84 / Rubin 84
PASS mokka-hetero-worker9 fixed=vr200: 4 NVIDIA Graphics Device|Rubin|10.7.0     (and the 8 other workers PASS)
IDENTITY fail=0
D3 revert: identity check rc=0 (want 0)
D3_REVERT_RC=1
```

The revert phase exited 1 only because its device-list diff compared list
order. The diff shows the same four (name, uuid, pciBusID) triples in a new
order. Order-insensitive comparison, plus the order in every real slice now
versus H1's dump:

```
$ diff <(jq -S ".[0] | sort_by(.name)" worker9-devices-pre.json) <(jq -S ".[0] | sort_by(.name)" worker9-devices-revert.json)
order-insensitive diff rc=0
pre order: gpu-0,gpu-3,gpu-1,gpu-2
revert order: gpu-3,gpu-1,gpu-2,gpu-0
== current device order of every real slice          == H1 dump (10:2xZ)
mokka-hetero-worker8 gpu-2,gpu-0,gpu-3,gpu-1          mokka-hetero-worker8 gpu-2,gpu-0,gpu-3,gpu-1
mokka-hetero-worker9 gpu-3,gpu-1,gpu-2,gpu-0          mokka-hetero-worker9 gpu-0,gpu-3,gpu-1,gpu-2
(the other 7 real slices: identical order now and in H1's dump; worker5/6 gpu-0..3, worker4 gpu-3,gpu-0,gpu-1,gpu-2)
```

The source explains it: with default gates, dra-driver v0.5.0 fills the slice
by ranging over `allocatablesMap map[PCIBusID]AllocatableDevices`, whose value
type is itself a map (`cmd/gpu-kubelet-plugin/driver.go:489-495`,
`allocatable.go:42-44` at 90b3a591). Go map order is randomised, so each
plugin start publishes a new order. Only the plugin I restarted (worker9, twice)
changed order. The gate had a genuine bug. I fixed `h5-d3.sh` to compare the
device set sorted by name (commented in the script) and did not re-run the
revert phase, to avoid another relabel cycle. The fixed comparison is the
command above, run on the same two files: rc=0.

D2 (vLLM discovery) was not re-run under D3: the brief asks for the identity
count check, and the vLLM image is loaded only on worker/worker4/worker7 (H1
step 8), not on worker9.

## Step 5: final checker run after D3, and end state

`H5_RUN=final bash ~/mokka-hetero/h5/check-scenarios.sh; echo CHECK_FINAL_RC=$?`
(log `logs/h5-check-final.log`, 15:48:28Z to 15:49:45Z):

```
PASS S1 ... (16 checks) ... PASS S1 cleanup: 0 pods and 0 claims in sched-test after 2.6s
REPORT S1b vr200-naive-mem: allocated devices by architecture: Blackwell=5 Rubin=7
REPORT S1b vr200-naive-cc10: allocated devices by architecture: Blackwell=2 Rubin=10
15:48:47Z TIME S2 fill bound: 84/84 bound after 8.3s (since apply)
PASS S2 ... (8 checks) ...
EVENT S2 extra FailedScheduling count=1 message: 0/64 nodes are available: 1 node(s) had untolerated taint(s), 63 cannot allocate all claims. still not schedulable, preemption: 0/64 nodes are available: 64 Preemption is not helpful for scheduling.
PASS S3 ... (10 checks) ...
EVENT S3 B (latest of 18) s3-rack-b-8-p6ltb count=1 message: 0/64 nodes are available: 1 node(s) had untolerated taint(s), 54 cannot allocate all claims, 9 node(s) didn't match pod affinity rules. ...
15:49:45Z SUMMARY run=final pass=42 fail=0
CHECK_FINAL_RC=0
```

End state, the start-state script run again (`logs/h5-end-state.txt`), rc=0:
64/64 Ready, 336 devices (Blackwell 84 / Hopper 168 / Rubin 84), 3 racks and
3 cliques x 18, no clique on a real node, KWOK stages unchanged, 0
ResourceClaims anywhere, every kind node container `restarts=0 started
2026-09-23T10:10:57Z dev-nvidia=0` (so `s3b-hide-host-gpu.sh --restart` was
never needed), `Mem: available 9848` (start: 10488).

Left in the cluster: namespace `sched-test` with 6 ResourceClaimTemplates
(h100-x1, gb300-x1, vr200-x1, vr200-x4, vr200-naive-mem, vr200-naive-cc10), no
pods, no claims. H4's `detect-vllm` templates are untouched. Delete with
`kubectl delete ns sched-test`.

## Wall-clock (both full runs)

| scenario | apply -> all bound | apply -> all Running | server-side create -> PodScheduled | scenario total incl. cleanup |
|---|---|---|---|---|
| S1 (12 pods) | 1.5s / 1.5s | 1.6s / 1.6s | max 0s / 1s | 4.7s / 5.1s |
| S1b (24 pods) | 1.7s / 1.6s | 1.8s / 1.7s | max 1s / 1s | 5.3s / 5.3s |
| S2 fill (84 pods, 12 real) | 8.4s / 8.3s | 8.6s / 9.7s | max 5s, first-to-last 7s (both) | 38.5s / 40.1s (includes the 20s hold on the extra pod) |
| S3 A (18 pods x 4 GPUs) | 1.6s / 1.6s | 1.7s / 1.7s | max 0s (both) | 26.1s / 26.6s (includes the 20s hold on B) |

(green1 / final). The scheduler emitted the S2 and S3 FailedScheduling events
within 0-1s of the pod's creation.

## Findings and concerns

1. **F1: device order in a ResourceSlice is random per plugin start
   (dra-driver v0.5.0, default gates).** Measured on worker9 (see D3 revert),
   explained by `driver.go:489-495` ranging over nested Go maps. Effects: a
   plugin restart can rewrite a slice even when nothing else changed. Any tool
   that compares slices by list position breaks: my first revert gate did,
   and a clone that copies by position would too (H3's clone and slice check
   join by name, so they are unaffected). INFERENCE: with first-fit
   allocation, which device a claim gets can differ after a restart. Upstream
   driver behaviour, not Mokka.
2. **F2: a profile relabel may race node-agent's teardown (INFERENCE, not
   reproduced).** Moving a node between nvml-mock releases makes one
   DaemonSet delete its pod and another create one on the same node, with no
   ordering between them. The old pod's `Discard` removes shared paths under
   `/var/lib/nvml-mock` (agent.go:104-109, gpudriver.go:75-110). I avoided it
   with a two-step relabel. Worth a Mokka owner's look, since the
   device-plugin fleet guide's pattern (one release per profile, nodes selected
   by label) makes a relabel the natural way to repoint a node.
3. **F3: naive selectors mix GB300 into VR200 workloads at any scale.** S1b:
   3/12 and 5/12 (memory 288Gi), 2/12 and 2/12 (CC major 10) across the two
   full runs. MS2 at 84 pods: 42/42. Only a selector that includes architecture
   (or the full H2 conjunction) separates them. The fixed-expectation checks
   catch it (MS1/MS2 KILLED).
4. S1 placed all 12 pods on KWOK nodes. INFERENCE: this is scoring, since the
   fake nodes are 64-CPU and the real workers 4-CPU. S2 (12 real + 72 KWOK)
   is the scenario that proves DRA prepare and Running on the real tier. MS3
   also placed 12 real VR200 devices.
5. Image deviation: scenario pods run `registry.k8s.io/pause:3.10` (present
   on every node) instead of H2's `busybox:1.36` (on no node). pause never opens
   the injected device nodes, which avoids H4's F1 surface (real L4 minors in
   mock claims) by construction.

## Artefacts

- VM: `~/mokka-hetero/h5/` (all scripts, `manifests/`, `mutants/ms{1,2,3}` +
  `.out`), `~/mokka-hetero/logs/h5-*`, dumps `~/mokka-hetero/out/h5/{green1,final,mut-ms1,mut-ms2,mut-ms3}/<scenario>/{dump.json,assert.txt,...}`,
  dump mutants `~/mokka-hetero/out/h5/dump-mutants-green1/`, D3 state `~/mokka-hetero/out/h5/d3/`.
- Local: `/tmp/mokka-hetero-58fc971e/h5/scripts/` (authoring copies,
  identical to the VM's), `/tmp/mokka-hetero-58fc971e/h5/logs/` (all 18 H5
  logs), `/tmp/mokka-hetero-58fc971e/h5/h5/` (VM script and manifest tree),
  `/tmp/mokka-hetero-58fc971e/h5/out/h5/d3/`.

## Status

DONE_WITH_CONCERNS. S1/S2/S3 pass on the real + KWOK cluster through one
scheduler (42/42, run twice, the second time after D3, rc=0). All 3 scenario
mutants and all 24 assertion mutants are killed. D3 turned the
fixed-expectation identity check RED (Rubin 80 / Blackwell 88) and the revert
turned it GREEN, with no kind node container restart. The concerns: F1 (my
first revert gate failed on slice device order, a driver behaviour; fixed
and explained), F2 (relabel teardown race, INFERENCE) and the documented
deviations (pause image, two-step relabel). Nothing was pushed, posted or
opened.
