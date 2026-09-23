# Task H7 report: Kueue TAS on the KWOK VR200 rack (design b)

Status: **DONE_WITH_CONCERNS** (2026-09-23, 15:49Z to 18:04Z, with a Teleport
gap from 17:20Z to 17:30Z).

## Result

Kueue v0.19.5 TAS placed an 18-pod, 4-GPU-per-pod job on the 18 trays of the
KWOK VR200 rack, one pod per tray, all in one clique. In every pod, DRA
allocated the tray's own 4 Rubin devices. k7 passed twice (10/10 PASS, rc=0):
- T1: a 19-pod job was refused by TOPOLOGY on the empty rack.
- T2: job A (18 pods) was admitted, and the pods landed on kwok-vr200-00..17
  (pod index i on tray i). Each pod's TAS hostname selector equals its bound
  node. Each claim holds 4 devices from the pod's own node, and all 72 devices
  in the kwok-vr200 pools are `Rubin|NVIDIA Graphics Device|10.7.0`.
- T3: job B was held by TOPOLOGY while 72 of 144 quota was reserved.
- T4: B was admitted once A was deleted.

The quota-72 mutant turned T1 and T3 RED. Restoring the quota gave GREEN
again. k6 behaved exactly as H6 predicted for both variants. Kueue stays
installed; the test jobs, pods, claims and the k6 namespace are gone.

Concerns:
- **C1.** One of k7's 10 assertions does not discriminate. "T3 quota has room
  (72 of 144 reserved)" checks only that the reservation is 72. The "of 144" is
  literal text, and the check PASSED under the quota-72 mutant (see the
  Mutation section). The mutant was caught by T3's topology-message assertion
  and by T1. The fix, not applied: read the ClusterQueue's nominalQuota and
  assert that it is greater than the reservation.
- **C2.** I did not mutation-test D2 (k2 webhook check) or the InternalIP check
  in k3. Both went green on the real objects only.
- **C3.** The Kueue image came from the Mac, not the gcr.io staging route (D1).
  The digest chain was re-verified on the VM.
- **C4 (INFERENCE, R1).** The Kueue visibility APIServices stay registered. If
  the Kueue pod dies, API discovery breaks cluster-wide.
- **C5.** Design (b) has the blind spot k6 shows: DRA usage outside Kueue is
  invisible to TAS. Kueue then admits a job that cannot run fully.

Before the renewal, the Teleport session expired at 17:20Z
(`tsh status` at 17:26:45Z showed `Valid until: 2026-09-23 19:20:24 +0200 CEST [EXPIRED]`).
The call that was in flight then (scp of `h7-k3-mutants.sh` and `k4-m3.yaml`)
hung, and I stopped it without re-login. At 17:30Z `ls` on the VM showed the
files had not landed. I resumed after the chief confirmed the renewal.

VM work: `~/mokka-hetero/h7/` (H6 drafts plus H7 scripts), logs
`~/mokka-hetero/logs/h7-*.log`. Local copies: `/tmp/mokka-hetero-58fc971e/h7/`.

State re-read at 17:30Z after the renewal (`tsh status`: valid until 2026-09-24 03:29:30 +0200):
```
$ helm list -n kueue-system
kueue	kueue-system	1	2026-09-23 16:49:46.836553842 +0000 UTC	deployed	kueue-0.19.5	v0.19.5
$ kubectl -n kueue-system get pods -o wide
kueue-controller-manager-cc987478c-dmpff   1/1   Running   0   41m   10.244.3.9   mokka-hetero-worker
$ kubectl get topologies,resourceflavors,clusterqueues ; kubectl get localqueues -A ; kubectl get ns mokka-hetero-kueue
No resources found / No resources found / namespaces "mokka-hetero-kueue" not found     (k4 not applied)
$ nodes grouped by their tas-* allocatable
10 (none)
18 mokka-hetero.nvidia.com/tas-gb300-gpu=4
18 mokka-hetero.nvidia.com/tas-h100-gpu=8
18 mokka-hetero.nvidia.com/tas-vr200-gpu=4
$ ls ~/mokka-hetero/h7/   -> no h7-k3-mutants.sh, no k4-m3.yaml: the hung scp did NOT land
```

| Step | State |
|---|---|
| k1 Kueue image | DONE fail=0 (source changed, D1) |
| k2 install Kueue 0.19.5 | DONE fail=0 (webhook check fixed, D2) |
| k3 accounting capacity on the 54 KWOK trays | DONE fail=0 (16:51Z, re-run 17:35Z with H6's InternalIP check) |
| k3 check mutants | DONE: live PASS=64 FAIL=0; M1/M2/M3 each FAIL=1 |
| k4 TAS objects | DONE fail=0: dry-run rc=0, CEL mutant rejected, 3 CQs Active |
| k5+k7 T0-T4 | DONE: green1 10/10 PASS rc=0 (17:40Z); green2 10/10 PASS rc=0 (18:00Z) |
| k7 mutation (quota 72) | DONE: RED (T1 and T3 FAIL, rc=1), restored GREEN (rc=0); C1 |
| k6 blind spot | DONE fail=0: hidden variant admitted with 1 pod stuck; visible variant refused "17 out of 18" |
| cleanup | DONE: 0 jobs, pods, claims and workloads in mokka-hetero-kueue; blind namespace deleted; Kueue, k4 objects and the accounting capacity kept |

Local copies of the logs: `/tmp/mokka-hetero-58fc971e/h7/logs/`:
- `h7-k1..k4*.log`, `h7-k3-mutants.log`
- `h7-k7-green1.log`, `h7-k7-mutant-quota72.log`, `h7-k7-green2.log`, `h7-k7-mutant-quota.log`
- `h7-k6-blindspot.log`
- pod and claim dumps as JSON

The green1 and green2 pod dumps are different runs: `cmp` differs, and the
first pod is `tas-a-0-v4mt9` vs `tas-a-0-ks28c`.

## Deviations from H6's drafts

- **D1 (k1 image source).** H6's k1 pulls from `gcr.io/k8s-staging-kueue/kueue`,
  which is not anonymously readable. Evidence:
  - VM: `curl .../v2/token?scope=repository:k8s-staging-kueue/kueue:pull&service=gcr.io`
    prints `gcr.io token http=403`.
  - Mac (a probe file from 15:48Z): `{"errors":[{"code":"UNAUTHORIZED","message":"not authenticated: No valid credential was supplied."}]}`.
  - The promoter manifest names `us-central1-docker.pkg.dev/k8s-staging-images/kueue`
    as `src: true`, and the VM resets `*.pkg.dev`.
  - registry.k8s.io on the VM redirects to pkg.dev: `HTTP/2 307`,
    `location: https://us-west2-docker.pkg.dev/v2/k8s-artifacts-prod/images/kueue/kueue/manifests/sha256:a5594970...`.

  Instead, the Mac pulled the image from registry.k8s.io by the amd64 child of
  the promoter-pinned index and saved it (OCI archive, 63 MB). `tsh scp` copied
  it to the VM, and `h7-k1-kueue-image.sh` re-verified every link of the digest
  chain on the VM before `kind load`.
- **D2 (k2 webhook check).** H6's jq accepted `namespaceSelector == null` for the
  webhooks on cluster-scoped Kueue objects. That holds for the helm render only:
  the apiserver defaults an unset selector to `{}`, and the live output shows
  `ns={}` for the 8 Kueue-group webhooks. Unchanged, the check would have failed
  on correct objects. The replacement fails any webhook that is not scoped to
  `mokka-hetero-kueue` and has a rule outside `kueue.x-k8s.io`. I did not
  mutation-test the new check (no time before the expiry).
- **D3 (mechanical).** Logs and temp files renamed `h6-` to `h7-`, and
  `cd "$(dirname "$0")" || exit 1` added to k2, k3 and k7. Nothing else changed
  in k3 or k7 (`diff ../h6/kueue/k2-kueue-install.sh h7-k2-kueue-install.sh`
  showed only the log line before the D2 edit).

- **D4.** More script changes:
  - k4 is wrapped in `h7-k4-tas-objects.sh`: Namespace first, then the server
    dry-run, the k4-m3 mutant, the apply, and a wait for Active.
  - k7 gained one line that saves the claims to `/tmp/h7-tas-a-claims.json`.
    This is evidence only; the assertions are unchanged.
  - H6's `k6-blindspot-pod.yaml` names namespace `mokka-hetero-sched`, which
    does not exist; H5's namespace is `sched-test` and is not mine. So
    `h7-k6-blindspot.sh` builds the same pod in its own namespace
    `mokka-hetero-kueue-blind`, with a copy of the vr200-x4 template and
    `registry.k8s.io/pause:3.10`. The namespace is deleted at the end.
- **Not used:** the chief's pointer to H6's Mac-side archive
  (`h6/kueue/kueue-v0.19.5-amd64.oci.tar`) and H6's new `k1-kueue-image.sh`.
  My k1 had already loaded the same image at 16:01Z, verified against the same
  pins: index a5594970, amd64 manifest 6ac15f95. I did not load it twice.

## k1: Kueue image (`h7-k1-kueue-image.sh`, log `logs/h7-k1-kueue-image.log`)

Mac side (15:5xZ):
```
$ regctl manifest get --format raw-body registry.k8s.io/kueue/kueue@sha256:a5594970...; shasum -a 256
regctl rc=0
sha256 raw index: sha256:a55949705d7ab1fe38034da56c5af95deecec3da0abebb209a372f7a5c414a2d
linux/amd64 sha256:6ac15f950a8e904f994ccfa3bfe71a1a4129a09654ee5c3be1a492e329f03a11
$ grep -nF '"sha256:a5594970...2d": ["v0.19.5"]' promoter images.yaml (kubernetes/k8s.io main)
159:    "sha256:a55949705d7ab1fe38034da56c5af95deecec3da0abebb209a372f7a5c414a2d": ["v0.19.5"]
grep rc=0
mutant (last nibble 2d -> 3d): grep rc=1
$ docker pull --platform linux/amd64 registry.k8s.io/kueue/kueue@sha256:6ac15f95...; docker save --platform linux/amd64
pull rc=0  Digest: sha256:6ac15f950a8e904f994ccfa3bfe71a1a4129a09654ee5c3be1a492e329f03a11
tar index.json -> manifest sha256:6ac15f95..., io.containerd.image.name=registry.k8s.io/kueue/kueue:v0.19.5
```

VM side, verbatim (rc=0):
```
start 2026-09-23T16:01:08Z
promoter fetch (VM) rc=0
159:    "sha256:a55949705d7ab1fe38034da56c5af95deecec3da0abebb209a372f7a5c414a2d": ["v0.19.5"]
PASS promoter pins v0.19.5 to sha256:a55949705d7ab1fe38034da56c5af95deecec3da0abebb209a372f7a5c414a2d
index-raw.json sha256: sha256:a55949705d7ab1fe38034da56c5af95deecec3da0abebb209a372f7a5c414a2d
index linux/amd64 child: sha256:6ac15f950a8e904f994ccfa3bfe71a1a4129a09654ee5c3be1a492e329f03a11
tar index.json: target=sha256:6ac15f950a8e904f994ccfa3bfe71a1a4129a09654ee5c3be1a492e329f03a11 name=registry.k8s.io/kueue/kueue:v0.19.5 entries=1
blobs verified: 16, bad=0
manifest sha256:6ac15f95...: config=sha256:52b1b9203b4401cffa98ce448d336cdb54b23db3c94ffe794be49e9716f86874 layers=14
PASS the tar holds exactly the manifest, config and 14 layers the pinned index names
kind load rc=0
mokka-hetero-control-plane: registry.k8s.io/kueue/kueue:v0.19.5 sha256:6ac15f950a8e904f994ccfa3bfe71a1a4129a09654ee5c3be1a492e329f03a11
mokka-hetero-worker .. worker9: (the same line on all 9 workers)
DONE fail=0 2026-09-23T16:01:25Z
```
There are 16 blobs: the manifest, the config and 14 layers.

## k2: install (`h7-k2-kueue-install.sh`, log `logs/h7-k2-kueue-install.log`)

Baseline before the install: no Mutating or ValidatingWebhookConfiguration
existed on the cluster (`kubectl get mutatingwebhookconfigurations,validatingwebhookconfigurations -o name`
was empty), and there were no non-Local APIServices.

```
start 2026-09-23T16:49:46Z
kueue-0.19.5.tgz: OK
== DeviceClass gpu.nvidia.com extendedResourceName
nvidia.com/gpu
== DRAExtendedResource gate as the apiserver reports it
kubernetes_feature_enabled{name="DRAExtendedResource",stage="BETA"} 1
STATUS: deployed  REVISION: 1
helm rc=0
deployment "kueue-controller-manager" successfully rolled out
rollout rc=0
mclusterqueue.kb.io fp=Fail ns={} groups=kueue.x-k8s.io         (+ mresourceflavor, mworkload, vclusterqueue, vcohort, vresourceflavor, vworkload: ns={} kueue.x-k8s.io)
mjob.kb.io fp=Fail ns={"matchLabels":{"kubernetes.io/metadata.name":"mokka-hetero-kueue"}} groups=batch
mpod.kb.io fp=Ignore ns={"matchLabels":{"kubernetes.io/metadata.name":"mokka-hetero-kueue"}} groups=
mdeployment/mstatefulset/vdeployment/vstatefulset/vpod: fp=Ignore, scoped to mokka-hetero-kueue
(all other framework webhooks: fp=Fail, scoped to mokka-hetero-kueue)
kueue webhooks total: 43
PASS all namespaced webhooks scoped to mokka-hetero-kueue
pod webhook failurePolicy: Ignore
== live manager config
  deviceClassMappings:
  - deviceClassNames:
    - gpu.nvidia.com
    name: mokka-hetero.nvidia.com/dra-gpu
== controller log: config errors or DRA mapping errors
"Configuration loaded" ... managedJobsNamespaceSelector: kubernetes.io/metadata.name: mokka-hetero-kueue ... frameworks: [batch/job] ... deviceClassMappings [...]
"level":"error" ... "Skipping admission check controller setup: Provisioning Requests not supported" (no ProvisioningRequest CRD; unrelated to TAS)
DONE fail=0 2026-09-23T16:50:01Z
```

What the live cluster confirms:
- H6 F-A2, which was INFERENCE, now holds on the live class: `gpu.nvidia.com`
  maps `nvidia.com/gpu`, and DRAExtendedResource is enabled.
- The 43 webhooks match H6's render, and only the 8 Kueue-group webhooks carry
  `{}`.

## k3: accounting capacity (`h7-k3-shadow-capacity.sh`, log `logs/h7-k3-shadow-capacity.log`)

```
$ bash h7-k3-shadow-capacity.sh; echo "k3 rc=$?"
k3 rc=0
start 2026-09-23T16:51:00Z
== verify: allocatable == slice devices on every KWOK node; no tas-* on real nodes
     64 PASS
kwok nodes verified: 54 (want 54)
DONE fail=0 2026-09-23T16:51:10Z
PASS kwok-gb300-00 mokka-hetero.nvidia.com/tas-gb300-gpu=4 slice=4
PASS kwok-h100-00 mokka-hetero.nvidia.com/tas-h100-gpu=8 slice=8
PASS kwok-vr200-00 mokka-hetero.nvidia.com/tas-vr200-gpu=4 slice=4
PASS kwok-vr200-17 mokka-hetero.nvidia.com/tas-vr200-gpu=4 slice=4
PASS mokka-hetero-control-plane real/control node carries no tas-* resource
PASS mokka-hetero-worker7 real/control node carries no tas-* resource
```
(The `uniq -c -w 4` summary line groups on the first 4 characters, so "64 PASS"
covers all 64 nodes: 54 KWOK and 10 real.)

### k3 re-run after the renewal (17:35Z), with H6's new InternalIP check added

H6 added a check to its k3: every KWOK InternalIP must still be 172.18.250.x.
I copied that block into `h7-k3-shadow-capacity.sh`; a `diff` against H6's new
version showed no other difference apart from my `cd` line. The InternalIP
check itself was not mutation-tested.
```
$ bash h7-k3-shadow-capacity.sh; echo "k3 rc=$?"
k3 rc=0
start 2026-09-23T17:34:54Z
     64 PASS ...
kwok nodes verified: 54 (want 54)
PASS all KWOK InternalIPs still 172.18.250.x
DONE fail=0 2026-09-23T17:35:04Z
```

### k3 mutants (`h7-k3-mutants.sh`, log `logs/h7-k3-mutants.log`)

The script uses awk to pull k3's own verify jq program out of the script, so the
program is never re-typed. It runs that program on the dump k3 just wrote, then
on three edits of that dump:
```
$ bash h7-k3-mutants.sh; echo "mutants rc=$?"
mutants rc=0
extracted program: 13 lines, sha256 a4a0f79f4cf178a8
live (as k3 left it): PASS=64 FAIL=0
M1 kwok-vr200-05 declares 8, slice has 4: PASS=63 FAIL=1
FAIL kwok-vr200-05 tas=[{"key":"mokka-hetero.nvidia.com/tas-vr200-gpu","value":"8"}] slice=4
M2 kwok-vr200-06 carries the gb300 key: PASS=63 FAIL=1
FAIL kwok-vr200-06 tas=[{"key":"mokka-hetero.nvidia.com/tas-gb300-gpu","value":"4"}] slice=4
M3 real worker7 carries a tas key: PASS=63 FAIL=1
FAIL mokka-hetero-worker7 real node carries [{"key":"mokka-hetero.nvidia.com/tas-vr200-gpu","value":"4"}]
```

## k4: TAS objects (`h7-k4-tas-objects.sh`, log `logs/h7-k4-tas-objects.log`)

On the first run (17:35Z) the server dry-run failed with rc=1:
`namespaces "mokka-hetero-kueue" not found`. A dry-run does not create the
Namespace, so the namespaced objects in the same file cannot be checked. The
script now creates only the Namespace first. Second run:
```
start 2026-09-23T17:39:19Z
namespace/mokka-hetero-kueue created
... 13 objects "(server dry run)"
k4 server dry-run rc=0
k4-m3 (mutant) server dry-run rc=1
The ClusterQueue "vr200" is invalid: spec.resourceGroups[0]: Invalid value: flavors must have the same number of resources as the coveredResources
PASS mutant k4-m3 rejected by the server
k4 apply rc=0
PASS ClusterQueue vr200 Active / PASS ClusterQueue gb300 Active / PASS ClusterQueue h100 Active
[{"nodeLabel":"nvidia.com/gpu.clique"},{"nodeLabel":"kubernetes.io/hostname"}]
DONE fail=0 2026-09-23T17:39:21Z
```
This closes H6's Risk 4. The mutant that survived H6's offline validator (it
drops `dra-gpu` from coveredResources) is rejected by the server's CRD CEL rule.

The live ClusterQueue status has the fields k7's `cq_used` reads, so T0 and T3
read real values rather than the `// "0"` fallback:
`{"keys":["admittedWorkloads","conditions","flavorsReservation","flavorsUsage","pendingWorkloads","reservingWorkloads"],"fr":[{"name":"vr200-rack","resources":[{"borrowed":"0","name":"mokka-hetero.nvidia.com/dra-gpu","total":"0"},{"borrowed":"0","name":"mokka-hetero.nvidia.com/tas-vr200-gpu","total":"0"}]}],"conds":[{"type":"Active","status":"True","reason":"Ready"}]}`.
The SGPURack identity matches the jq path k7 uses:
`{"cliqueID":0,"fabricUUID":"6b0453b6-5432-5c2d-a9b4-f8aa9a7b5739","rackGroup":"vr200","rackIndex":0}`.

## k5 + k7: T0-T4 (`h7-k7-tas-check.sh`)

H8's claims at the time (read-only listing): all 9 were on real worker7/8/9
pools (`mokka-hetero-cd` workload plus the `nvidia` CD daemons). None was on a
KWOK pool, so T0's "rack empty" guard was valid.

green1 (log `logs/h7-k7-green1.log`, rc file `k7 rc=0`), verbatim:
```
start 2026-09-23T17:40:05Z
== T0 preconditions
PASS no allocated device in the VR200 rack
PASS accounting resource equals slice device count on all 18 VR200 trays
PASS ClusterQueue vr200 has no reservation
== T1 tas-c19 on the empty rack
job.batch/tas-c19 created
QuotaReserved: False|Pending|couldn't assign flavors to pod set main: topology "mokka-hetero-rack" allows to fit only 18 out of 19 pod(s)
PASS T1 19 trays held by topology
== T2 tas-a
job.batch/tas-a created
pods=18 running=18 distinct_nodes=18 kwok_vr200_nodes=18 cliques=["6b0453b6-5432-5c2d-a9b4-f8aa9a7b5739.0"] selector_eq_node=true
PASS T2 18 pods, 18 trays, one rack (6b0453b6-5432-5c2d-a9b4-f8aa9a7b5739.0), TAS hostname == bound node
PASS T2 18 claims, 4 devices each, all from the pod's own node
== T3 tas-b while tas-a holds the rack
vr200 reservation of mokka-hetero.nvidia.com/tas-vr200-gpu: 72 of 144
job.batch/tas-b created
QuotaReserved: False|Pending|couldn't assign flavors to pod set main: topology "mokka-hetero-rack" doesn't allow to fit any of 18 pod(s). Total nodes: 18; excluded: resource "mokka-hetero.nvidia.com/tas-vr200-gpu": 18
PASS T3 quota has room (72 of 144 reserved)
PASS T3 tas-b held by topology
PASS T3 tas-b created no pods
== T4 release tas-a; tas-b must now be admitted
PASS T4 tas-b admitted once the rack was free
DONE fail=0 2026-09-23T17:40:20Z
```

Job A placement (green1 pod dump, `logs/h7-k7-green1-tas-a-pods.json`). Pod
index i landed on `kwok-vr200-<i>` for all 18 pods. Every pod has no scheduling
gate left, requests `tas-vr200-gpu: 4`, and carries the nodeSelector the Kueue
ungater wrote:
```
idx=0 node=kwok-vr200-00 sel={"kubernetes.io/hostname":"kwok-vr200-00","mokka-hetero.nvidia.com/gpu-type":"vr200"} gates=0 claims=tas-a-0-v4mt9-gpus-q54vf tasreq=4
...
idx=17 node=kwok-vr200-17 sel={"kubernetes.io/hostname":"kwok-vr200-17","mokka-hetero.nvidia.com/gpu-type":"vr200"} gates=0 claims=tas-a-17-456hk-gpus-dbnx6 tasreq=4
```

DRA vs TAS cross-check (green2 claim dump, `logs/h7-k7-green2-tas-a-claims.json`,
pod index -> node -> allocated `pool/device`). All 18 rows have the same shape:
```
idx=0 node=kwok-vr200-00 devices=kwok-vr200-00/gpu-2,kwok-vr200-00/gpu-0,kwok-vr200-00/gpu-3,kwok-vr200-00/gpu-1
...
idx=17 node=kwok-vr200-17 devices=kwok-vr200-17/gpu-2,kwok-vr200-17/gpu-0,kwok-vr200-17/gpu-3,kwok-vr200-17/gpu-1
$ identity of every device in the kwok-vr200-* pools (ResourceSlices, 18:02Z)
72 Rubin|NVIDIA Graphics Device|10.7.0
```

green2 (after the mutation, quota restored; `logs/h7-k7-green2.log`): 10 PASS,
0 FAIL, `DONE fail=0 2026-09-23T18:00:05Z`, with the same T1 and T3 messages as
green1. The mutant script recorded `k7 after restore rc=0`.

A third run, not started by me, was found at 18:06:59Z. `h7-k7-tas-check.log`
was rewritten at 18:06:50Z, and a `tas-b` job was briefly present in
mokka-hetero-kueue. No H7 process was running on the VM (`ps` grep empty), and my
rc files date from 17:40, 18:00 and 18:03Z. INFERENCE: it was the chief's
verification run. Its log shows `start 2026-09-23T18:06:37Z`, the same 10 PASS
lines, `DONE fail=0 2026-09-23T18:06:50Z`, and it cleaned up
(`No resources found in mokka-hetero-kueue namespace`). The Kueue pod was still
Running with 0 restarts, and both visibility APIServices were Available=True
(R1 has not triggered).

## Mutation: ClusterQueue vr200 quota 144 -> 72 (`h7-k7-mutant-quota.sh`)

This is H6's probe mutant M2, run on the live cluster. With room for only one
rack, "B waits" becomes a quota fact rather than a topology fact.
```
== mutant: quota 72
clusterqueue.kueue.x-k8s.io/vr200 patched
quotas now: {"mokka-hetero.nvidia.com/tas-vr200-gpu":"72","mokka-hetero.nvidia.com/dra-gpu":"72"}
k7 on mutant rc=1
PASS no allocated device in the VR200 rack
PASS accounting resource equals slice device count on all 18 VR200 trays
PASS ClusterQueue vr200 has no reservation
FAIL T1 unexpected: False|Pending|couldn't assign flavors to pod set main: insufficient quota for mokka-hetero.nvidia.com/dra-gpu in flavor vr200-rack, previously considered podsets requests (0) + current podset request (76) > maximum capacity (72), insufficient quota for mokka-hetero.nvidia.com/tas-vr200-gpu in flavor vr200-rack, ... (76) > maximum capacity (72)
PASS T2 18 pods, 18 trays, one rack (6b0453b6-5432-5c2d-a9b4-f8aa9a7b5739.0), TAS hostname == bound node
PASS T2 18 claims, 4 devices each, all from the pod's own node
FAIL T3 tas-b reason is not topology: False|Pending|couldn't assign flavors to pod set main: insufficient unused quota for mokka-hetero.nvidia.com/dra-gpu in flavor vr200-rack, 72 more needed, insufficient unused quota for mokka-hetero.nvidia.com/tas-vr200-gpu in flavor vr200-rack, 72 more needed
PASS T3 quota has room (72 of 144 reserved)        <- survived the mutant (C1)
PASS T3 tas-b created no pods
PASS T4 tas-b admitted once the rack was free
DONE fail=1 2026-09-23T17:59:50Z
== restore quota from k4
quotas now: {"mokka-hetero.nvidia.com/tas-vr200-gpu":"144","mokka-hetero.nvidia.com/dra-gpu":"144"}
k7 after restore rc=0
DONE fail=0 2026-09-23T18:00:05Z
RESULT mutant RED, restored GREEN
```
What this shows:
- T1 and T3 tell a quota hold apart from a topology hold. They match Kueue's
  topology message exactly, and the quota message ("insufficient
  (unused) quota") is rejected.
- Kueue charges the DRA claim (`dra-gpu`) to quota as well as the accounting
  resource. Both appear in the quota message.
- The T3 "quota has room" line is literal text over a check of `reserved == 72`
  only, so it did not catch this mutant (C1).

## k6: blind spot (`h7-k6-blindspot.sh`, log `logs/h7-k6-blindspot.log`, `k6 rc=0`)

A plain pod outside Kueue, in namespace `mokka-hetero-kueue-blind`, takes the 4
Rubin devices of kwok-vr200-00 through DRA.
```
start 2026-09-23T18:02:31Z
== variant hidden (no accounting request)
blind claim blindspot-tray-gpus-nwvgw: kwok-vr200-00/gpu-2,kwok-vr200-00/gpu-0,kwok-vr200-00/gpu-3,kwok-vr200-00/gpu-1
blind pod node=kwok-vr200-00 tas-request=
job.batch/tas-a created
tas-a workload: ["QuotaReserved=True QuotaReserved: Quota reserved in ClusterQueue vr200","Admitted=True Admitted: The workload is admitted"]
tas-a pods=18 running=17 pending=1
not running: tas-a-0-csprm phase=Pending node=- hostnameSelector=kwok-vr200-00 gates=0
event FailedScheduling count=1: 0/64 nodes are available: 1 cannot allocate all claims, 1 node(s) had untolerated taint(s), 62 node(s) didn't match Pod's node affinity/selector. still not schedulable, preemption: 0/64 nodes are available: 64 Preemption is not helpful for scheduling.
PASS hidden: Kueue admitted tas-a although one tray is held outside Kueue
PASS hidden: 17 Running, the 1 Pending pod is the one TAS pinned to kwok-vr200-00
after teardown: pods=0 claims=0
== variant visible (the blind pod also requests mokka-hetero.nvidia.com/tas-vr200-gpu: 4)
blind claim blindspot-tray-gpus-jtlzl: kwok-vr200-00/gpu-2,kwok-vr200-00/gpu-0,kwok-vr200-00/gpu-3,kwok-vr200-00/gpu-1
blind pod node=kwok-vr200-00 tas-request={"mokka-hetero.nvidia.com/tas-vr200-gpu":"4"}
tas-a workload: ["QuotaReserved=False Pending: couldn't assign flavors to pod set main: topology \"mokka-hetero-rack\" allows to fit only 17 out of 18 pod(s). Total nodes: 18; excluded: resource \"mokka-hetero.nvidia.com/tas-vr200-gpu\": 1"]
PASS visible: TAS refuses tas-a, 17 of 18 fit
PASS visible: tas-a created no pods
after teardown: pods=0 claims=0
left: ns mokka-hetero-kueue-blind Error from server (NotFound): namespaces "mokka-hetero-kueue-blind" not found; claims on kwok-vr200 pools: 0
DONE fail=0 2026-09-23T18:03:08Z
```
What this shows:
- TAS counts exactly what the accounting resource declares, nothing more. Kueue
  never looks at DRA.
- **Hidden variant.** Kueue admitted a job that cannot run fully. The ungater
  pinned pod 0 to the occupied tray, and the kube-scheduler (DRA) refused it:
  "1 cannot allocate all claims". Kueue does not re-place that pod.
- **Visible variant.** The same occupancy, declared through the accounting
  resource, makes TAS refuse the job up front.
- So design (b) is correct only while everything that takes a VR200 tray also
  requests the accounting resource. That is the operational rule this design
  needs (H6 F-A1/F-A2 context).

## Final state (18:03:24Z)

```
$ kubectl -n mokka-hetero-kueue get jobs,pods,resourceclaims,workloads
No resources found in mokka-hetero-kueue namespace.
$ clusterqueues: gb300 True 0 0 / h100 True 0 0 / vr200 True 0 0   (NAME ACTIVE ADMITTED PENDING)
$ vr200 quotas: {"mokka-hetero.nvidia.com/tas-vr200-gpu":"144","mokka-hetero.nvidia.com/dra-gpu":"144"}
$ kueue-controller-manager-cc987478c-dmpff   Running   0 restarts
$ apiservices: v1beta1/v1beta2.visibility.kueue.x-k8s.io  kueue-system/kueue-visibility-server  True
$ gpu.nvidia.com devices by architecture: Blackwell=84 Hopper=168 Rubin=84
$ claims allocated on kwok pools: 0
$ namespaces: kueue-system, mokka-hetero-kueue (mokka-hetero-kueue-blind deleted)
```
Kept on purpose: the Kueue release, the k4 objects (Topology, 3 flavors, 3
ClusterQueues, 3 LocalQueues, the vr200-x4 template) and the accounting
capacity on the 54 KWOK trays. The KWOK trays keep
`mokka-hetero.nvidia.com/tas-<type>-gpu`. Real nodes never had it.

## Risks found during prep

- **R1 (INFERENCE).** The chart creates the APIServices
  `v1beta1/v1beta2.visibility.kueue.x-k8s.io` unconditionally (rendered
  `templates/visibility/apiservice_v1beta{1,2}.yaml`, no `if`). The Kueue manager
  serves them. If the Kueue pod goes down, API discovery becomes partial for
  every client, which can break `helm` for H8. Leaving Kueue installed (step 8)
  keeps that exposure.
