# Task H3 report: KWOK tier, racks, cloned ResourceSlices on `mokka-hetero`

Status: DONE_WITH_CONCERNS (2026-09-23 11:54Z to 13:50Z). See "Findings and
concerns" and "Status" at the end.

VM work lives under `~/mokka-hetero/` (H2 drafts in `h2/`, H3 scripts in
`h3/`, logs in `logs/h3-*`). Local copies of H3 scripts and copied-back logs:
`/tmp/mokka-hetero-58fc971e/h3/`.

| Step | State |
|---|---|
| 0 pre-flight | DONE |
| 1 KWOK install | DONE (deviation: image source, see 1a) |
| 2 54 fake nodes | DONE (deviation: preset InternalIP, see 2a) |
| 3 racks | DONE, 19/19 checks, 5/5 mutants killed |
| 4 slice clones | DONE, 9/9 checks, 6/6 mutants killed; 336 = 48 + 288 |
| 5 snapshot | DONE, readyz ok, 64/64 Ready, 0 restarts |

## Step 0: pre-flight

Cluster as H1 left it: 10 nodes Ready (v1.36.1), 46 pods Running, no
`detect-vllm` namespace yet (H4 had not started at 11:56Z).

H2 drafts copied to `~/mokka-hetero/h2/` (kwok, dra, racks, scenarios; not
`src/`). Hashes on the VM equal H2's report and the local files; `nodes.yaml`
regenerates byte-identically:

```
$ sha256sum kwok/*.yaml dra/clone-slices.sh racks/sgpu-*.yaml   (on the VM)
a4c16e6431e382dcb5c1903139344b7a68652f16a6460337fe17a678a426f405  kwok/kwok-v0.8.0.yaml
47097c3fe28a5f87d692a8159aaf5769b0f951e8255cd6c07d92d53a2245393c  kwok/nodes.yaml
aac5c0580f270e9b3aeca8c7bd9c6475a37e4e63b204f62c0f6ff7228a6fce53  kwok/stage-fast-v0.8.0-no-pod-complete.yaml
2f28d95564ec43056c0873f7a25ac7d2a5bba4c8496c72f8b3ee73fd4f54ee24  kwok/stage-fast-v0.8.0.yaml
b4fdf9109f093505c8646e9da76f27484c85af40ed7eb018303ac394a2714deb  dra/clone-slices.sh
cb950a1d145abbb3a81e21469c0140884d69c89360b5b4568059ff1c0f50e29d  racks/sgpu-inventory.yaml
b834ee14a29c053a94267ff077db9f903e97f95a9ba407b968514359467040c3  racks/sgpu-rack-profiles.yaml
$ bash kwok/gen-nodes.sh > /tmp/h3-nodes-regen.yaml && cmp /tmp/h3-nodes-regen.yaml kwok/nodes.yaml
cmp rc=0
```

Live scheduling constraints of the real-tier workloads (confirms H2 F2 from the
cluster, not the chart):

```
$ kubectl -n <ns> get <r> -o json | jq -c '{nodeSelector, tolerations, affinity}'
== mokka/ds/nvml-mock-h100   {"nodeSelector":{"nvml-mock/profile":"h100"},"tolerations":[{"operator":"Exists"}],"affinity":null}
== mokka/ds/nvml-mock-gb300  {"nodeSelector":{"nvml-mock/profile":"gb300"},"tolerations":[{"operator":"Exists"}],"affinity":null}
== mokka/ds/nvml-mock-vr200  {"nodeSelector":{"nvml-mock/profile":"vr200"},"tolerations":[{"operator":"Exists"}],"affinity":null}
== nvidia/ds/dra-driver-nvidia-gpu-kubelet-plugin  {"nodeSelector":null,"tolerations":[{"effect":"NoSchedule","key":"nvidia.com/gpu","operator":"Exists"}],"affinity":{...nodeSelectorTerms: pci-10de / pci-0302_10de / pci-0300_10de / cpu-model.vendor_id=NVIDIA / nvidia.com/gpu.present=true}}
== kube-system/ds/kube-proxy {"nodeSelector":{"kubernetes.io/os":"linux"},"tolerations":[{"operator":"Exists"}],"affinity":null}
== kube-system/ds/kindnet    {"nodeSelector":{"kubernetes.io/os":"linux"},"tolerations":[{"operator":"Exists"}],"affinity":null}
== mokka/deploy/nvml-mock-h100-control-plane  {"nodeSelector":null,"tolerations":null,"affinity":null}
```

## Step 1: KWOK v0.8.0 in-cluster (DONE)

### 1a. The official image cannot be pulled from this VM (FOUND, WORKED AROUND)

First run of `h3/h3-s1-kwok.sh` (log `logs/h3-s1-kwok.log`, first run): the
kwok-controller pod sat in ImagePullBackOff and the gate went RED:

```
Warning  Failed  kubelet  Failed to pull image "registry.k8s.io/kwok/kwok:v0.8.0": ... failed to do request: Head "https://us-west2-docker.pkg.dev/v2/k8s-artifacts-prod/images/kwok/kwok/manifests/v0.8.0?rid=...": read tcp 172.18.0.9:41544->74.125.142.82:443: read: connection reset by peer
controller phase/ready/restarts: Pending/false/0
FAIL controller not exactly one Running/ready pod with 0 restarts
DONE fail=1 2026-09-23T12:05:00Z
```

The host Docker daemon fails the same way, so it is the VM's network, not kind:

```
$ docker pull registry.k8s.io/kwok/kwok:v0.8.0
Error response from daemon: ... Head "https://us-west2-docker.pkg.dev/v2/k8s-artifacts-prod/images/kwok/kwok/manifests/v0.8.0?rid=...": read tcp <private-ip>:48090->74.125.142.82:443: read: connection reset by peer
pull rc=1
$ curl -w "%{http_code}" https://<host>/v2/     (per host)
registry.k8s.io 401          us-west2-docker.pkg.dev  (35) Recv failure: Connection reset by peer
us-docker.pkg.dev 000        europe-docker.pkg.dev 000   asia-docker.pkg.dev 000   europe-west1-docker.pkg.dev 000
gcr.io 401   ghcr.io 401   registry-1.docker.io 401   proxy.golang.org 404
```

Every `*.pkg.dev` host is reset; `registry.k8s.io` answers but redirects to
one. Workaround with digest provenance (`h3/h3-s1b-kwok-image.sh`): the
Kubernetes image promoter copies staging images to prod by digest, and
kubernetes/k8s.io `registry.k8s.io/images/k8s-staging-kwok/images.yaml` pins
kwok v0.8.0 to index `sha256:6d25aa8f...c2b26f0`. The script refuses to go on
unless the `gcr.io/k8s-staging-kwok/kwok` index hashes to exactly that digest,
then pulls its linux/amd64 child by digest, tags it with its official name,
and `kind load image-archive`s it into the 9 workers. `kwok-v0.8.0.yaml` is
applied unchanged (`image: registry.k8s.io/kwok/kwok:v0.8.0`,
`imagePullPolicy: IfNotPresent`, so the kubelet uses the loaded image).

```
$ cat ~/mokka-hetero/logs/h3-s1b-kwok-image.log
start 2026-09-23T12:11:56Z
promoter fetch rc=0
promoter line:     "sha256:6d25aa8fbdfe78845423160bf125b5513f9522e2770981f0945c2a250c2b26f0": [ "v0.8.0" ]
staging index inspect rc=0
staging index sha256 of raw bytes: sha256:6d25aa8fbdfe78845423160bf125b5513f9522e2770981f0945c2a250c2b26f0
index linux/amd64 child: sha256:28ee38abba19bd0b89600b1b367c32480da45f1d954c80d14db5fc74feee83f2
Digest: sha256:28ee38abba19bd0b89600b1b367c32480da45f1d954c80d14db5fc74feee83f2
pull rc=0
tag rc=0
save rc=0
-rw------- 1 <user> <user> 41245696 Sep 23 12:11 ~/mokka-hetero/tmp/kwok-v0.8.0-amd64.tar
kind load rc=0
mokka-hetero-worker: registry.k8s.io/kwok/kwok:v0.8.0 sha256:28ee38abba19bd0b89600b1b367c32480da45f1d954c80d14db5fc74feee83f2
... (worker2..worker9: the same line)
DONE fail=0 2026-09-23T12:12:07Z
```

### 1b. Install and gate (PASS)

`h3/h3-s1-kwok.sh` applies `kwok-v0.8.0.yaml`, waits for the rollout, applies
`stage-fast-v0.8.0-no-pod-complete.yaml`, and exits non-zero unless the stage
set is exactly the four kept stages, `pod-complete` is absent, and there is
exactly one Running/ready controller pod with 0 restarts. After deleting the
ImagePullBackOff pod (the Deployment's own pod) it passed:

```
$ bash h3/h3-s1-kwok.sh ; echo "s1 rc=$?"
s1 rc=0
deployment "kwok-controller" successfully rolled out
rollout rc=0
apply stages rc=0
stage.kwok.x-k8s.io/node-heartbeat-with-lease
stage.kwok.x-k8s.io/node-initialize
stage.kwok.x-k8s.io/pod-delete
stage.kwok.x-k8s.io/pod-ready
PASS stages exactly: node-heartbeat-with-lease node-initialize pod-delete pod-ready
PASS pod-complete absent
kwok-controller-77fb44794-2m9k6   1/1   Running   0   12s   10.244.2.6   mokka-hetero-worker5
controller phase/ready/restarts: Running/true/0
{"msg":"Watch nodes","annotation":"kwok.x-k8s.io/node=fake","label":""}
DONE fail=0 2026-09-23T12:12:37Z
```

The controller landed on worker5, which is not one of H4's nodes.

## Step 2: 54 fake nodes (DONE, with one required change to H2's node template)

### 2a. KWOK's default node IP would crash kindnet on the real tier (FOUND, AVOIDED)

H2's template sets no `status.addresses`, so KWOK's `node-initialize` stage
fills InternalIP with `NodeIP`, which the in-cluster Deployment sets to the
controller's pod IP (`kwok-v0.8.0.yaml`: `--node-ip=$(POD_IP)`; stage
`{{ if not $hasInternalIP }}{{ with NodeIP }} - address ... type: InternalIP`).
kube-controller-manager gives every Node a podCIDR (`--allocate-node-cidrs=true
--cluster-cidr=10.244.0.0/16`). kindnetd (`docker.io/kindest/kindnetd:v20260528-9350166c`)
on every real node then routes each other Node's podCIDR via that Node's
InternalIP. Its source at the image commit
(`raw.githubusercontent.com/kubernetes-sigs/kind/9350166c/images/kindnetd/cmd/kindnetd/main.go`):

```
main.go:291   err = reconcileNodes(nodes)
main.go:295   klog.Infof("Failed to reconcile routes, retrying after error: %v", err)
main.go:299   panic("Maximum retries reconciling node routes: " + err.Error())
routes.go:63  if err := netlink.RouteAdd(&routeToDst); err != nil { return err }
```

Kernel half measured in a throwaway unprivileged container (own netns, default
bridge; no cluster node touched), mirroring a worker's route shape:

```
$ docker run --rm --cap-add NET_ADMIN --network bridge --entrypoint sh <kindest/node 3489c7674813> -c '...'
    inet 172.17.0.2/16 brd 172.17.255.255 scope global eth0
mirror-route: 10.244.2.0/24 via 172.17.0.1         mirror rc=0
T1 KWOK default InternalIP = kwok-controller pod IP
   ip route add 10.244.12.0/24 via 10.244.2.6  ->  Error: Nexthop has invalid gateway.   T1 rc=2
T2 preset InternalIP on the on-link subnet, high range
   ip route add 10.244.13.0/24 via 172.17.250.1                                          T2 rc=0
```

INFERENCE (deliberately not reproduced on the cluster): with H2's template
unchanged, kindnetd on 9 of the 10 real nodes would fail the route add,
retry 5 times and panic, and kindnet would crash-loop across the real tier,
including H4's nodes.

Options weighed: (1) preset a unique on-link InternalIP per fake node;
(2) KWOK `--node-ip=$(HOST_IP)`, rejected because kindnetd on that host would
take the fake Node for itself (`nodeIPs.Has(hostIP)`) and rewrite its CNI config;
(3) stop podCIDR allocation, not possible without changing kube-controller-manager.
Chosen: (1). `h3/gen-nodes-h3.sh` is H2's generator plus a preset
`status.addresses` (InternalIP `172.18.250.<n>`, vr200 .1-.18, gb300 .21-.38,
h100 .41-.58, plus Hostname). That range is on the kind network's on-link
`172.18.0.0/16`, far above Docker's sequential IPAM pointer (real nodes are
.2-.11), and never a real node's IP. kindnetd then installs harmless dead-end
routes to the fake podCIDRs. Side effect: apiserver-to-"kubelet" calls for fake
pods (`kubectl logs/exec` on KWOK pods) go to an unreachable IP instead of the
kwok-controller. The scenarios do not need them.

### 2b. Create and gate (PASS)

`h3/h3-s2-nodes.sh` (log `logs/h3-s2-nodes.log`, copied back). Gates, in order:
generator diff vs H2, generated set, server-side dry-run keeps
`status.addresses`, a one-node canary with read-only route checks on every real
node, then the other 53, then the brief's checks. It rolls back automatically if
the canary or kindnet fails.

```
$ bash h3/h3-s2-nodes.sh      (rc=0)
start 2026-09-23T12:47:59Z
== diff vs H2 nodes.yaml: removed=0 added=270 (want 0 and 270 = 5 x 54)
     54 >   - address: 172.18.250.N
     54 >   addresses:
     54 >   - address: kwok-<t>-N
     54 >     type: Hostname
     54 >     type: InternalIP
nodes=54
gb300=18 h100=18 vr200=18
PASS generated: 54, 18/18/18, no nvml-mock/profile, 54 unique 172.18.250.x
real InternalIPs: 172.18.0.10 172.18.0.11 172.18.0.2 172.18.0.3 172.18.0.4 172.18.0.5 172.18.0.6 172.18.0.7 172.18.0.8 172.18.0.9
PASS no fake IP equals an existing node IP
server dry-run kept: {"addresses":[{"address":"172.18.250.1","type":"InternalIP"},{"address":"kwok-vr200-00","type":"Hostname"}],"cpu":"64"}
== kindnet restarts before
mokka-hetero-control-plane 0 ... mokka-hetero-worker9 0   (10 pods, all 0)
node/kwok-vr200-00 created
node/kwok-vr200-00 condition met
kwok-vr200-00   Ready    <none>   36s   fake      172.18.250.1   <none>        <unknown>   kwok-v0.8.0 (amd64)   kwok-v0.8.0
canary addresses=[{"type":"InternalIP","address":"172.18.250.1"},{"type":"Hostname","address":"kwok-vr200-00"}] podCIDR=10.244.12.0/24
mokka-hetero-control-plane: 10.244.12.0/24 via 172.18.250.1 dev eth0
mokka-hetero-worker: 10.244.12.0/24 via 172.18.250.1 dev eth0
... (worker2..worker9: the same line)
PASS kindnet restarts unchanged
kindnet failure lines since 2026-09-23T12:48:00Z: 0
PASS canary
     18 node/kwok-gb300-NN created
     18 node/kwok-h100-NN created
     17 node/kwok-vr200-NN created
wait all rc=0
== fake nodes            (count STATUS gpu-type nvml-mock/profile)
     18 Ready gb300 -
     18 Ready h100 -
     18 Ready vr200 -
fake nodes Ready: 54
type vr200: 18
type gb300: 18
type h100: 18
fake nodes carrying nvml-mock/profile: 0
fake InternalIPs kept (54 unique 172.18.250.x): true
== fake-node routes on each real node (want 54, all via 172.18.250.x)
mokka-hetero-control-plane: 54   ... mokka-hetero-worker9: 54   (all 10 nodes: 54)
PASS kindnet restarts unchanged
kindnet failure lines since 2026-09-23T12:48:00Z: 0
== pods on fake nodes (namespace owner-kind/owner phase)
     54 kube-system DaemonSet/kindnet Running
     54 kube-system DaemonSet/kube-proxy Running
nvml-mock / DRA / Mokka pods on fake nodes: none
== kubectl get pods -A -o wide, rows on kwok-* nodes, by namespace and name prefix
     54 kube-system kindnet-* Running
     54 kube-system kube-proxy-* Running
== real-tier DaemonSets (desired/ready unchanged)
kube-system kindnet desired=64 ready=64
kube-system kube-proxy desired=64 ready=64
mokka nvml-mock-gb300 desired=3 ready=3
mokka nvml-mock-h100 desired=3 ready=3
mokka nvml-mock-vr200 desired=3 ready=3
nvidia dra-driver-nvidia-gpu-kubelet-plugin desired=9 ready=9
DONE fail=0 2026-09-23T12:49:24Z
```

The forbidden-pod check (`nvml-mock / DRA / Mokka pods on fake nodes`) selects
on namespace `mokka` or `nvidia`, or a pod name matching
`nvml-mock|dra-driver|control-plane`, among pods whose `spec.nodeName` starts
with `kwok-`. The same selector over all pods finds the real-tier pods (see the
DaemonSet lines above), so it can match. kindnet and kube-proxy tolerate every
taint and get fake Running pods, as H2 predicted.

Positive control for that selector (same jq, without the `kwok-` nodeName filter), run at 12:50Z:

```
$ kubectl get pods -A -o json | jq -r '.items[] | select(.metadata.namespace == "mokka" or .metadata.namespace == "nvidia" or (.metadata.name | test("nvml-mock|dra-driver|control-plane"))) | "\(.metadata.namespace) \(.spec.nodeName)"' | sort | uniq -c
      4 kube-system mokka-hetero-control-plane      (etcd/apiserver/controller-manager/scheduler pods)
      2 mokka mokka-hetero-worker7                  (nvml-mock-vr200 + the Mokka control plane)
      1 mokka mokka-hetero-worker{,2,3,4,5,6,8,9}   (one nvml-mock pod each)
      1 nvidia mokka-hetero-worker{,2,...,9}        (one DRA kubelet plugin each)
```

## Step 3: racks (DONE)

Before applying, the two ValidatingAdmissionPolicies in the cluster:

```
$ kubectl get validatingadmissionpolicy -o json | jq -c '...'
{"name":"nvml-mock-h100-control-plane-sgpurack-writes","matchResources":[{"resources":["sgpuracks"],"operations":["CREATE","UPDATE"]}],"validations":["SGPURack writes are restricted to the Mokka controller or garbage-collector deletion-finalizer removal"]}
{"name":"resourceslices-policy-dra-driver-nvidia-gpu","matchConditions":[{"expression":"request.userInfo.username == \"system:serviceaccount:nvidia:nvidia-dra-driver-dra-driver-nvidia-gpu-service-account\"","name":"isRestrictedUser"}], ...}
```

H3 writes only SGPURackProfiles and the SGPUInventory (never SGPURacks), and the
ResourceSlice policy matches only the driver's ServiceAccount (H2 was right), so
admin-created clones are allowed. The control plane's ClusterRole
`control-plane.mokka.nvidia.com` has `nodes: get,list,watch,patch`.

### 3a. Apply (`h3/h3-s3a-racks-apply.sh`, log `logs/h3-s3a-racks-apply.log`)

```
sgpurackprofile.mokka.nvidia.com/hetero-{vr200-nvl72,gb300-nvl72,h100-hgx} created (server dry run)   dry-run rc=0
sgpuinventory.mokka.nvidia.com/mokka-hetero created (server dry run)                                    dry-run rc=0
apply profiles rc=0
apply inventory rc=0
t+1s racks=1 assigned+clique nodes=12
t+6s racks=3 assigned+clique nodes=54
NAME                                                  NODES/RACK   GPUS/NODE
sgpurackprofile.mokka.nvidia.com/hetero-gb300-nvl72   18           4
sgpurackprofile.mokka.nvidia.com/hetero-h100-hgx      18           8
sgpurackprofile.mokka.nvidia.com/hetero-vr200-nvl72   18           4
inventory status: capacity {gpus: 288, nodes: 54, racks: 3}; conditions Accepted/Programmed/RequestsSatisfied/ResolvedRefs all True;
  rackGroups gb300 {gpus 72, nodes 18} h100 {gpus 144, nodes 18} vr200 {gpus 72, nodes 18}, each allocatedNodes 18, pendingNodes 0
DONE ok=1 2026-09-23T12:53:04Z
```

The control plane logged two transient reconcile errors during the first second.
Both cleared on requeue, and all four inventory conditions are True:

```
{"level":"error","time":"2026-09-23T12:52:58.794Z","msg":"Controller reconciliation failed","error":"allocation input changed during reconciliation","key":"mokka-hetero"}
{"level":"error","time":"2026-09-23T12:52:59.179Z","msg":"Controller reconciliation failed","error":"owned rack is missing from the informer cache: rack \"mokka-hetero-h100-0-7dba7a642e5a\"","key":"mokka-hetero"}
```

Live SGPURack shape (confirms the paths `clone-slices.sh` uses:
`.spec.identity.rackGroup`, `.spec.nodes[].nodeRef.name`, `.gpus[].pciAddress`, `.uuid`):

```
{"specKeys":["identity","inventoryRef","nodes","profileRef"],
 "identity":{"cliqueID":0,"fabricUUID":"34a5a1db-6cd8-5f1f-ac99-737c1ac575e1","rackGroup":"gb300","rackIndex":0},
 "node0":{"index":0,"nodeRef":{"name":"kwok-gb300-00","uid":"ee7640a3-..."}},
 "gpu0":{"hostProcessorIndex":0,"index":0,"minorNumber":0,"numaNode":0,"pciAddress":"0000:0a:00.0","rootComplex":"pci0000:00","serial":"05735189687758379441","uuid":"GPU-bea4fc77-e8cb-5d17-b3c5-935d2bc97bbf"}}
```

### 3b. Checks and mutation verification (`h3/h3-s3b-racks-check.sh` + `h3/check-racks.jq`, log `logs/h3-s3b-racks-check.log`)

The checks are one jq program over dumps of nodes, SGPURacks and ResourceSlices.
The same program then runs on five copies of the dumps, each with exactly one
field altered (the cluster is never mutated). The script exits non-zero if a
live check fails or a mutant survives.

```
$ bash h3/h3-s3b-racks-check.sh ; echo "s3b rc=$?"
s3b rc=0
NAME                                          GROUPS             NODES   GPUS   AGE
sgpuinventory.mokka.nvidia.com/mokka-hetero   gb300,h100,vr200   54      288    14m
NAME                                                          INVENTORY      RACK GROUP   RACK   PROFILE              ASSIGNED   AGE
sgpurack.mokka.nvidia.com/mokka-hetero-gb300-0-b87a5def5070   mokka-hetero   gb300        0      hetero-gb300-nvl72   18         14m
sgpurack.mokka.nvidia.com/mokka-hetero-h100-0-7dba7a642e5a    mokka-hetero   h100         0      hetero-h100-hgx      18         14m
sgpurack.mokka.nvidia.com/mokka-hetero-vr200-0-36e187099dcb   mokka-hetero   vr200        0      hetero-vr200-nvl72   18         14m
TYPE vr200: nodes=18 clique-values=[6b0453b6-5432-5c2d-a9b4-f8aa9a7b5739.0 x18] sgpu-assigned=18 racks=1 rack=mokka-hetero-vr200-0-36e187099dcb rack-identity-clique=6b0453b6-5432-5c2d-a9b4-f8aa9a7b5739.0
PASS vr200: exactly one clique value on its 18 nodes, equal to the rack's fabricUUID.cliqueID
PASS vr200: mokka.nvidia.com/sgpu-assigned=true on 18
PASS vr200: its one rack binds exactly its 18 fake nodes (name and uid)
PASS vr200: every rack node has 4 slots whose pciAddress set equals mokka-hetero-worker8's pciBusID set [0002:81:00.0 0002:c1:00.0 000a:81:00.0 000a:e1:00.0]
PASS vr200: sgpu-assignment annotation rackGroup=vr200 on all 18
TYPE gb300: nodes=18 clique-values=[34a5a1db-6cd8-5f1f-ac99-737c1ac575e1.0 x18] sgpu-assigned=18 racks=1 rack=mokka-hetero-gb300-0-b87a5def5070 rack-identity-clique=34a5a1db-6cd8-5f1f-ac99-737c1ac575e1.0
PASS gb300: (the same 5 checks; pciBusID set of worker5 [0000:0a:00.0 0000:0b:00.0 0000:4a:00.0 0000:4b:00.0])
TYPE h100: nodes=18 clique-values=[618cfd92-1ae5-560d-8b55-8d8865e2d28b.0 x18] sgpu-assigned=18 racks=1 rack=mokka-hetero-h100-0-7dba7a642e5a rack-identity-clique=618cfd92-1ae5-560d-8b55-8d8865e2d28b.0
PASS h100: (the same 5 checks; 8 slots, pciBusID set of worker2 [0000:1a:00.0 0000:1b:00.0 0000:4a:00.0 0000:4b:00.0 0000:8a:00.0 0000:8b:00.0 0000:ca:00.0 0000:cb:00.0])
PASS 3 distinct clique values across the 54 fake nodes
PASS 288 rack GPU uuids, all distinct
PASS no rack uuid equals any of the 16 distinct real-tier uuids
PASS the 10 real nodes carry no clique, sgpu-assigned or sgpu-assignment (H2 P2)
live: jq rc=0 PASS=19 FAIL=0 (want 19 PASS, 0 FAIL)
== per type: nvidia.com/gpu.clique values on the 18 fake nodes, and sgpu-assigned count
-- vr200     18 6b0453b6-5432-5c2d-a9b4-f8aa9a7b5739.0     sgpu-assigned=true: 18
-- gb300     18 34a5a1db-6cd8-5f1f-ac99-737c1ac575e1.0     sgpu-assigned=true: 18
-- h100      18 618cfd92-1ae5-560d-8b55-8d8865e2d28b.0     sgpu-assigned=true: 18
-- real nodes with a clique label: 0
-- example assignment annotation (kwok-vr200-00):
{"v":1,"inventory":{"name":"mokka-hetero","uid":"d77e7a91-..."},"rack":{"name":"mokka-hetero-vr200-0-36e187099dcb","uid":"e951ccd5-..."},"profile":{"name":"hetero-vr200-nvl72","uid":"31b1ee87-...","revision":"d55cc5de..."},"rackGroup":"vr200","rackIndex":0,"nodeIndex":0,"nodeUID":"7ed5a9a0-..."}
M1 kwok-vr200-05 clique: 6b0453b6-...5739.0 -> 34a5a1db-...75e1.0
KILLED M1: FAIL vr200: clique values [{"v":"34a5a1db-...75e1.0","n":1},{"v":"6b0453b6-...5739.0","n":17}]
M2 kwok-h100-03 sgpu-assigned: true -> <absent>
KILLED M2: FAIL h100: sgpu-assigned count 17
M3 worker7 clique: <absent> -> 6b0453b6-...5739.0
KILLED M3: FAIL real nodes 10, projected onto ["mokka-hetero-worker7"]
M4 vr200 rack node0 gpu1 pciAddress: 0002:c1:00.0 -> 0002:c2:00.0
KILLED M4: FAIL vr200: rack pciAddress vs real slice pciBusID [0002:81:00.0 0002:c1:00.0 000a:81:00.0 000a:e1:00.0]
M5 h100 rack node1 gpu0 uuid: GPU-072c1deb-... -> GPU-ec97ea90-...
KILLED M5: FAIL rack uuids 288, distinct 287
== mutant diffs (flattened leaf paths, live '<' vs mutant '>'; want exactly the one field)
m1-nodes: 2 changed line(s)   < / > ["items",41,"metadata","labels","nvidia.com/gpu.clique"]
m2-nodes: 1 changed line(s)   < ["items",21,"metadata","labels","mokka.nvidia.com/sgpu-assigned"],"true"
m3-nodes: 1 changed line(s)   > ["items",61,"metadata","labels","nvidia.com/gpu.clique"]
m4-racks: 2 changed line(s)   < / > ["items",2,"spec","nodes",0,"gpus",1,"pciAddress"]
m5-racks: 2 changed line(s)   < / > ["items",1,"spec","nodes",1,"gpus",0,"uuid"]
DONE fail=0 2026-09-23T13:07:35Z
```

Note for S3 (INFERENCE from H2's F5, not re-tested here): the H100 group has a
projected clique too (`618cfd92-....0`), which names the placement group and
not an NVLink partition.

## Step 4: cloned ResourceSlices (DONE)

### 4a. Clone (`h3/h3-s4a-clone.sh` running H2's `h2/dra/clone-slices.sh` unchanged, log `logs/h3-s4a-clone.log`)

Sources are real nodes H4 is not using (H4 works on worker, worker4 and worker7).
All real nodes of a type publish the same slice (H1 step 7). The wrapper
refuses a source whose `nvml-mock/profile` label or identity tuple is not the
expected one. It also records the 9 real slices' resourceVersions before and
after, to show they were not written.

```
$ bash h3/h3-s4a-clone.sh      (rc=0)
start 2026-09-23T13:45:11Z
source vr200: mokka-hetero-worker8 profile=vr200 tuple=[4 NVIDIA Graphics Device|Rubin|10.7.0]
source gb300: mokka-hetero-worker5 profile=gb300 tuple=[4 NVIDIA GB300 NVL|Blackwell|10.0.0]
source h100: mokka-hetero-worker2 profile=h100 tuple=[8 NVIDIA H100 80GB HBM3|Hopper|9.0.0]
real slices before: 00000-gpu.nvidia.com-mokka-hetero-worker-hc2jp@3139 ...-worker2-qkdv4@3152 ...-worker3-kpp5g@3148 ...-worker4-q6m2r@3140 ...-worker5-2ss7d@3124 ...-worker6-lm2zh@3156 ...-worker7-8b4xv@2290 ...-worker8-k4j2d@3151 ...-worker9-j5krf@3150
== clone vr200 from mokka-hetero-worker8
      1 OK: 18 vr200 KWOK slices cloned from mokka-hetero-worker8
     18 resourceslice.resource.k8s.io/kwok-vr200-NN-gpu.nvidia.com created
clone vr200 rc=0
== clone gb300 from mokka-hetero-worker5
      1 OK: 18 gb300 KWOK slices cloned from mokka-hetero-worker5
     18 resourceslice.resource.k8s.io/kwok-gb300-NN-gpu.nvidia.com created
clone gb300 rc=0
== clone h100 from mokka-hetero-worker2
      1 OK: 18 h100 KWOK slices cloned from mokka-hetero-worker2
     18 resourceslice.resource.k8s.io/kwok-h100-NN-gpu.nvidia.com created
clone h100 rc=0
PASS real slices untouched (same 9 names and resourceVersions)
DONE fail=0 2026-09-23T13:45:22Z
```

### 4b. Checks and mutation verification (`h3/h3-s4b-slices-check.sh` + `h3/check-slices.jq`, log `logs/h3-s4b-slices-check.log`)

```
$ bash h3/h3-s4b-slices-check.sh ; echo "s4b rc=$?"
s4b rc=0
== kubectl get resourceslices (count by node prefix)
     18 kwok-gb300-NN gpu.nvidia.com
     18 kwok-h100-NN gpu.nvidia.com
     18 kwok-vr200-NN gpu.nvidia.com
      1 mokka-hetero-worker{,2,...,9} gpu.nvidia.com   (one each)
DEVICES total=336 real=48 fake=288 slices: real=9 fake=54
TUPLE 84 NVIDIA GB300 NVL|Blackwell|10.0.0
TUPLE 84 NVIDIA Graphics Device|Rubin|10.7.0
TUPLE 168 NVIDIA H100 80GB HBM3|Hopper|9.0.0
PASS 336 gpu.nvidia.com devices = 48 real + 288 fake
PASS identity tuples are exactly Hopper 168, Blackwell 84, Rubin 84 (no other tuple)
PASS no duplicate (node, device) pairs among 336 devices
PASS each of the 54 fake nodes has exactly one slice holding 4 (vr200, gb300) or 8 (h100) devices of its own type
COUNT gb300: 18 nodes x 4 devices
COUNT h100: 18 nodes x 8 devices
COUNT vr200: 18 nodes x 4 devices
PASS 288 fake device uuids, all distinct
PASS every fake device uuid is its SGPURack slot uuid (joined on node + pciBusID)
PASS every fake device equals the same-named device of its type's source (worker8/5/2) on every attribute except uuid, and on capacity
PASS fake slices: owner Node (name and uid) = spec.nodeName; pool {name: node, generation: 1, resourceSliceCount: 1}
PASS real tier unchanged: 9 slices worker=8 worker2=8 worker3=8 worker4=4 worker5=4 worker6=4 worker7=4 worker8=4 worker9=4
live: jq rc=0 PASS=9 FAIL=0 (want 9 PASS, 0 FAIL)
== independent recount with plain kubectl + jq (no helper)
total gpu.nvidia.com devices: 336
84 NVIDIA GB300 NVL|Blackwell|10.0.0|288Gi
84 NVIDIA Graphics Device|Rubin|10.7.0|288Gi
168 NVIDIA H100 80GB HBM3|Hopper|9.0.0|80Gi
KILLED M1: FAIL device totals 340 = 48 real + 292 fake | FAIL tuple counts {...Rubin|10.7.0":88...} | FAIL 4 duplicate (node, device) pairs | FAIL fake nodes with a wrong slice count, device count or type: ["kwok-vr200-03"] | FAIL fake uuids 292, distinct 288 | FAIL identity differs from the source: []
KILLED M2: FAIL tuple counts {...,"NVIDIA Graphics Device|Blackwell|10.7.0":1,"NVIDIA Graphics Device|Rubin|10.7.0":83,...} | FAIL fake nodes with a wrong slice count, device count or type: ["kwok-vr200-10"] | FAIL identity differs from the source: ["kwok-vr200-10/gpu-3"]
KILLED M3: FAIL fake uuids 288, distinct 287 | FAIL uuid is not the rack slot's: ["kwok-gb300-04/gpu-0"]
KILLED M4: FAIL device totals 335 = 48 real + 287 fake | FAIL tuple counts {...Hopper|9.0.0":167} | FAIL fake nodes with a wrong slice count, device count or type: ["kwok-h100-07"] | FAIL fake uuids 287, distinct 287
KILLED M5: FAIL fake slice metadata: ["kwok-h100-11-gpu.nvidia.com"]
KILLED M6: FAIL identity differs from the source: ["kwok-gb300-09/gpu-2"]
== mutant diffs (flattened leaf paths, live '<' vs mutant '>')
s1: 63 changed line(s)   (all '>': one added slice object, items[63])
s2: 2 changed line(s)    items[55].spec.devices[2].attributes.architecture.string "Rubin" -> "Blackwell"
s3: 2 changed line(s)    items[13].spec.devices[0].attributes.uuid.string GPU-e97c53de-... -> GPU-907a8921-...
s4: 11 changed line(s)   (all '<': one removed device, items[34].spec.devices[7])
s5: 2 changed line(s)    items[38].spec.pool.name "kwok-h100-11" -> "kwok-h100-12"
s6: 2 changed line(s)    items[18].spec.devices[2].capacity.memory.value "288Gi" -> "287Gi"
DONE fail=0 2026-09-23T13:45:45Z
```

Mutants: M1 adds a second slice for one node, M2 changes one architecture, M3
gives one device a neighbour tray's uuid, M4 removes one device, M5 points one
pool at another node, M6 changes one capacity while keeping the identity tuple.
Each must produce its named FAIL line(s); all six were killed.

## Step 5: snapshot (DONE, `h3/h3-s5-snapshot.sh`, log `logs/h3-s5-snapshot.log`)

The script exits non-zero if the apiserver is not ready, nodes are not 64/64
Ready, a control-plane or KWOK container restarted, a real kindnet restarted, a
kind node container restarted since H1 created it, or `/dev/nvidia*` is back in
any kind node.

```
$ bash h3/h3-s5-snapshot.sh ; echo "s5 rc=$?"
s5 rc=0
 13:49:00 up 14 days,  2:45,  1 user,  load average: 1.06, 1.58, 1.65
               total        used        free      shared  buff/cache   available
Mem:           15363        4700        1045          74       10052       10662
Swap:           3924         997        2927
== kubectl get --raw /readyz
ok (rc=0)
readyz check passed
nodes total=64 ready=64 real=10 kwok=54
etcd-mokka-hetero-control-plane phase=Running restarts=0 started=2026-09-23T10:11:10Z
kube-apiserver-mokka-hetero-control-plane phase=Running restarts=0 started=2026-09-23T10:11:10Z
kube-controller-manager-mokka-hetero-control-plane phase=Running restarts=0 started=2026-09-23T10:11:10Z
kube-scheduler-mokka-hetero-control-plane phase=Running restarts=0 started=2026-09-23T10:11:10Z
kwok-controller-77fb44794-2m9k6 phase=Running restarts=0 started=2026-09-23T12:12:26Z
sum of restarts above: 0
10 real kindnet pods, restarts=0
nvml-mock-h100-control-plane-6df546f988-t44b9   1/1   Running   0   3h36m   10.244.8.2   mokka-hetero-worker7
== kind node containers: restart count and start time (H1 created them at ~10:11Z)
mokka-hetero-control-plane restarts/started=0 2026-09-23T10:10:57.148582361Z dev-nvidia=0
mokka-hetero-worker restarts/started=0 2026-09-23T10:10:57.179988128Z dev-nvidia=0
... (worker2..worker9: restarts 0, started 2026-09-23T10:10:57.1xZ, dev-nvidia=0)
== pods
    155 Running
not Running/Completed:            (none)
== docker stats (kind nodes)
mokka-hetero-control-plane 17.17% 974.6MiB / 15GiB     (H1 snapshot: 753.5MiB)
mokka-hetero-worker4 5.35% 692.1MiB    mokka-hetero-worker7 3.49% 582.9MiB    mokka-hetero-worker 3.44% 432.8MiB
(the other six workers 196-232 MiB)
3975 MiB across 10 containers      (H1 snapshot: 3571 MiB)
resourceslices=63 sgpuracks=3 leases(kube-node-lease)=64
DONE fail=0 2026-09-23T13:49:07Z
```

155 Running pods = H1's 46 + kwok-controller + 54 kindnet + 54 kube-proxy on
the fake nodes. No kind node container restarted, so
`s3b-hide-host-gpu.sh --restart` was not needed. Adding the KWOK tier cost
about 400 MiB across the kind containers (most of it the control-plane node)
and about 240 MB of host `available`.

## Findings and concerns

1. **This VM cannot pull anything from `registry.k8s.io`.** Every `*.pkg.dev`
   host resets the connection (1a). Any later wave that needs a
   registry.k8s.io image (for example Kueue, if the `h6/kueue-probe` work runs
   on the VM) will hit the same ImagePullBackOff. The workaround in
   `h3/h3-s1b-kwok-image.sh` is reusable: take the digest the promoter pins in
   kubernetes/k8s.io, pull that digest from `gcr.io/k8s-staging-<project>`, tag
   it with the official name, and `kind load image-archive` it. Content identity
   holds because the index digest is checked against the promoter pin.
2. **H2's `gen-nodes.sh` / `nodes.yaml` must not be used on this cluster.**
   Without a preset InternalIP, KWOK sets the fake nodes' IP to its own pod IP.
   The kernel rejects that as a route gateway (measured), and kindnetd panics
   after 5 failed reconciles (source). The crash itself is INFERENCE; I did not
   reproduce it on the cluster by design. Use `h3/gen-nodes-h3.sh` (local copy
   `/tmp/mokka-hetero-58fc971e/h3/scripts/gen-nodes-h3.sh`, output
   `/tmp/mokka-hetero-58fc971e/h3/nodes-h3.yaml`) for any fake node created later.
3. **Side effect of 2:** `kubectl logs/exec/port-forward` on pods bound to
   KWOK nodes will fail (the apiserver dials `172.18.250.x:10247`, which nothing
   answers). Scheduling, binding and KWOK's pod-ready stage do not use that path.
   INFERENCE from the stage template (`daemonEndpoints.kubeletEndpoint.Port: NodePort`)
   and the address choice; not exercised.
4. **DRA chart 0.5.0: the ResourceSlice ValidatingAdmissionPolicy restricts no
   one on this install** (outside H3 scope; recorded for the chief). The policy
   matches `system:serviceaccount:nvidia:nvidia-dra-driver-dra-driver-nvidia-gpu-service-account`,
   but the kubelet plugin runs as `...-service-account-kubeletplugin` and no
   ServiceAccount in `nvidia` has the matched name:
   ```
   plugin SA: nvidia-dra-driver-dra-driver-nvidia-gpu-service-account-kubeletplugin
   sa: compute-domain-daemon-service-account
   sa: default
   sa: nvidia-dra-driver-dra-driver-nvidia-gpu-service-account-controller
   sa: nvidia-dra-driver-dra-driver-nvidia-gpu-service-account-kubeletplugin
   request.userInfo.username == "system:serviceaccount:nvidia:nvidia-dra-driver-dra-driver-nvidia-gpu-service-account"
   ```
   INFERENCE: a kubelet plugin on one node could create or delete slices for any
   other node, including the KWOK clones. This corrects H2's "only restricts
   the driver's own ServiceAccount". H3's own conclusion (an admin can create
   the clones) is unaffected.
5. The Mokka control plane logged two transient reconcile errors in the first
   second after the inventory was applied (optimistic-concurrency style:
   `allocation input changed during reconciliation`, `owned rack is missing
   from the informer cache`). Both cleared on requeue, and all inventory
   conditions are True. Worth a look by Mokka owners, not a blocker.
6. For wave 2 (from what H3 set up, INFERENCE): the real VR200 devices are on
   worker7/8/9, and H4 allocates on worker7. S2 ("fill all 84 VR200") needs
   H4's claims gone first, or it will count 83. The VR200 rack clique exists
   only on the 18 KWOK trays; no real node has a clique (H2 precondition P2
   holds, and mutant M3 in 3b shows the check would catch a violation).

## Artefacts

- VM: `~/mokka-hetero/h3/` (scripts, `nodes-h3.yaml`, `nodes-h3-list.json`,
  `canary.json`), `~/mokka-hetero/logs/h3-*.log`, dumps and mutants under
  `~/mokka-hetero/out/h3/`, KWOK image tar `~/mokka-hetero/tmp/kwok-v0.8.0-amd64.tar`.
- Local: `/tmp/mokka-hetero-58fc971e/h3/scripts/` (all H3 scripts and jq
  programs), `/tmp/mokka-hetero-58fc971e/h3/logs/` (all 8 step logs),
  `/tmp/mokka-hetero-58fc971e/h3/nodes-h3.yaml`.

## Status

DONE_WITH_CONCERNS. All five steps done and gated (every gate's script exits
non-zero on failure; step 1's gate was seen RED, steps 3 and 4 were
mutation-verified). Two deviations from the brief: the KWOK image source (1a)
and the fake nodes' InternalIP (2a). Both were required to finish without
touching the real tier. Concerns 1, 2 and 4 matter beyond this task.
