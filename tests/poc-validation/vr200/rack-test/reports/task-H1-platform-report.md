# Task H1 report: real tier of `mokka-hetero` on <vm>

Status: DONE_WITH_CONCERNS (2026-09-23 10:01Z to 10:43Z). All 9 steps done;
see "Concerns" and "Status" at the end.

All VM work lives under `~/mokka-hetero/` (scripts in `scripts/`, logs in
`logs/`, dumps in `out/`). Local copies of every script:
`/tmp/mokka-hetero-58fc971e/h1/scripts/`. Copied-back artefacts:
`/tmp/mokka-hetero-58fc971e/h1/`.

## Pre-flight (VM state before any work)

```
$ tsh ssh <user>@<vm> 'hostname; uname -m; nproc; free -m; df -h ~ | tail -1; docker ps -a; docker images; kind get clusters; kind version; ...'
<vm>
x86_64
4
               total        used        free      shared  buff/cache   available
Mem:           15363        2551        8446          19        4738       12811
/dev/root       290G   46G  244G  16% /
CONTAINER ID   IMAGE     COMMAND   CREATED   STATUS    PORTS     NAMES
IMAGE   ID             DISK USAGE   CONTENT SIZE   EXTRA
kind v0.32.0 go1.26.3 linux/amd64
No kind clusters found.
Client Version: v1.36.0
version.BuildInfo{Version:"v4.2.4", ...}
go version go1.26.6 linux/amd64
 Runtimes: io.containerd.runc.v2 nvidia runc
 Default Runtime: runc
rc=0
```

inotify limits (10 kind nodes need headroom): `max_user_watches=1048576`,
`max_user_instances=1024` (read from `/proc/sys/fs/inotify/`; `sysctl` is not
on the non-login PATH).

## Step 1: source (DONE)

Script `scripts/s1-source.sh` (clone, `checkout --detach e8e49aeb`,
`fetch origin pull/872/head:pr872`, cherry-pick `merge-base..pr872`).
Log `logs/s1-source.log` (copied back), rc=0:

```
HEAD is now at e8e49aeb fix(node-agent): bind-mount the driver tree onto /run/nvidia/driver (#860)
 * [new ref]           refs/pull/872/head -> pr872
merge-base=29e9445d8a868adc412efbcf9b46b25ed2c19e7a
commits-to-pick=4
8058e1c9 fix(vr200): cover the profile in the utilization guard and correct its memory line
f707629c fix(vr200): carry the nameplate 288 GB of HBM4, not the capture's usable total
a9110640 test(vr200): join the per-profile assertion tables, fix the profile counts
bb9c07bd feat(nvml-mock): add vr200 profile (Vera-Rubin Superchip)
(4 cherry-picks, auto-merges only, no conflicts)
HEAD=de8a00dd278cacfab01ec87beedacc6cdfae72d3
TREE=06b4536078645d7fab16e9c7e5136a18aba9f00f
de8a00dd fix(vr200): cover the profile in the utilization guard and correct its memory line
21c2ea73 fix(vr200): carry the nameplate 288 GB of HBM4, not the capture's usable total
e88a8a18 test(vr200): join the per-profile assertion tables, fix the profile counts
fab400e3 feat(nvml-mock): add vr200 profile (Vera-Rubin Superchip)
e8e49aeb fix(node-agent): bind-mount the driver tree onto /run/nvidia/driver (#860)
4a44f73b chore: cleanup unused code + moved libcuda to shims (#789)
deployments/control-plane
deployments/mokka-crds
deployments/nvml-mock/helm/nvml-mock/profiles/vr200.yaml
```

The VM HEAD SHA differs from the chief's local 29cc7971 only because cherry-pick
stamps a new committer/date. The TREE is byte-identical to the local worktree:

```
$ git -C .worktrees/rack-hetero rev-parse 29cc7971^{tree}
06b4536078645d7fab16e9c7e5136a18aba9f00f
```

## Step 2: images (DONE)

`scripts/s2-build.sh` under nohup. No build args: both Dockerfile headers only
declare `GOLANG_VERSION` (defaults 1.26.6 / 1.26.7; go.mod says `go 1.26.0`) and
`GOPROXY` (public default); the Artifactory secret is optional.

```
$ cat ~/mokka-hetero/logs/s2-build.log
start 2026-09-23T10:03:31Z HEAD=de8a00dd278cacfab01ec87beedacc6cdfae72d3
nvml-mock rc=0 2026-09-23T10:08:42Z
control-plane rc=0 2026-09-23T10:10:27Z
[nvml-mock:hetero] sha256:9ef5b32c5617e71088e2c7af02694deea46cacda1276e83adb27ef773c8fa8e9 amd64 2026-09-23T10:08:37.019238345Z
[mokka-control-plane:hetero] sha256:cca92c4febe60789c30be1c1343b3cfc12ed649ea73c9b278d311f36ca843e86 amd64 2026-09-23T10:10:25.925728628Z
DONE rc1=0 rc2=0
```

The VM's Docker uses the containerd image store (`driver-type:
io.containerd.snapshotter.v1`), so these IDs are manifest digests; inside the
kind nodes `crictl` shows config digests (9c496bb053f63 / 9afd677bfb886) for the
same images. INFERENCE: same image, different digest kind; not re-verified.

## Step 3: cluster (DONE, plus one required fix, see Step 3b)

docs/guides/dra.md (read in full in the VM tree, identical to local) gives no
node image, so kind v0.32.0's default is used: `kindest/node:v1.36.1@sha256:3489c767...`.
Config `scripts/kind-mokka-hetero.yaml` = the guide's Step 1 verbatim
(`featureGates.DynamicResourceAllocation: true`, containerd `enable_cdi = true`
patch, apiserver `runtime-config: resource.k8s.io/v1beta1=true`) plus 9 workers
labelled `nvml-mock/profile` x3 each and `nvidia.com/gpu.present: "true"`.

Deviations, both deliberate:
- `nvidia.com/gpu.present=true` is set in the kind config on the 9 workers only,
  not `kubectl label node --all` as in the single-node guide: the control plane
  runs no nvml-mock, so a DRA kubelet plugin there would find no driver tree.
- `mokka.nvidia.com/type=sgpu` NOT applied: only the device-plugin DaemonSet
  (docs/guides/device-plugin.md Step 3 `nodeSelector`) needs it, and the device
  plugin is out of scope. Neither the DRA guide nor the nvml-mock chart
  selects on it (`grep -n nodeSelector templates/daemonset.yaml` shows only
  `.Values.nodeSelector`).

```
$ cat ~/mokka-hetero/logs/s3-cluster.log   (trimmed)
start 2026-09-23T10:10:38Z
 [ok] Ensuring node image (kindest/node:v1.36.1)
 [ok] Joining worker nodes
kind create rc=0 2026-09-23T10:11:40Z
NAME                         STATUS     ROLES           VERSION   CONTAINER-RUNTIME    PROFILE   GPU.PRESENT
mokka-hetero-control-plane   Ready      control-plane   v1.36.1   containerd://2.3.1
mokka-hetero-worker          NotReady   <none>          v1.36.1   containerd://2.3.1   h100      true
... worker2, worker3 h100; worker4-6 gb300; worker7-9 vr200 (all true)
DONE rc=0

$ kubectl wait --for=condition=Ready node --all --timeout=180s     -> all 10 "condition met"
$ kubectl api-versions | grep resource.k8s.io
resource.k8s.io/v1
resource.k8s.io/v1beta1
$ docker exec mokka-hetero-worker containerd config dump | grep -n -iE "enable_cdi|cdi_spec_dirs|^version"
1:version = 4
51:    enable_cdi = true
52:    cdi_spec_dirs = ['/etc/cdi', '/var/run/cdi']
$ docker exec mokka-hetero-control-plane cat /etc/kubernetes/manifests/kube-apiserver.yaml | grep -E "runtime-config|feature-gates"
    - --runtime-config=resource.k8s.io/v1beta1=true
    - --feature-gates=DynamicResourceAllocation=true
```

### Step 3b: the VM's real L4 leaks into every kind node (FOUND AND FIXED)

The first run of the Step 7 gate went RED: every worker published exactly ONE
device (`devices=1`, `gpu-0` only) instead of 8/4. Root cause, proved by
experiment:

```
# VM host has a real GPU and its device nodes:
$ cat /proc/driver/nvidia/version | head -1
NVRM version: NVIDIA UNIX Open Kernel Module for x86_64  595.71.05  Release Build ...
$ nvidia-smi -L
GPU 0: NVIDIA L4 (UUID: GPU-0f6e1fd0-503e-4b79-0624-16dae4f6797f)
$ ls -la /dev/nvidia*              (host)
crw-rw-rw- 1 root root 195,   0 Sep  9 11:08 /dev/nvidia0
crw-rw-rw- 1 root root 195, 255 Sep  9 11:08 /dev/nvidiactl
crw-rw-rw- 1 root root 510,   0 Sep  9 11:08 /dev/nvidia-uvm
...
# kind nodes are privileged runc containers, so Docker copies ALL host devices
# into each node's /dev tmpfs, and privileged pods (DRA plugin) inherit them:
$ docker inspect mokka-hetero-worker --format "privileged={{.HostConfig.Privileged}} runtime={{.HostConfig.Runtime}}"
privileged=true runtime=runc
$ docker exec mokka-hetero-worker ls -la /dev/nvidia0
crw-rw-rw- 1 root root 195,   0 Sep 23 10:10 /dev/nvidia0
$ kubectl -n nvidia exec dra-driver-nvidia-gpu-kubelet-plugin-hl7zw -c gpus -- ls -la /dev/nvidia0
crw-rw-rw-    1 root     root      195,   0 Sep 23 10:14 /dev/nvidia0
# the mock engine then filters to the device nodes that exist:
$ docker exec mokka-hetero-worker env -i MOCK_NVML_DEBUG=1 LD_PRELOAD=/var/lib/nvml-mock/driver/usr/lib64/libnvidia-ml.so.1 /var/lib/nvml-mock/driver/usr/bin/nvidia-smi -L
[CONFIG] Loaded YAML config: 8 devices, driver 550.163.01
...
[ENGINE] Device visibility filtering: 1 of 8 GPUs visible (by /dev/nvidia* presence)
GPU 0: NVIDIA H100 80GB HBM3 (UUID: GPU-01000100-0000-0000-0000-000000000000)
```

The filter is `detectVisibleDevicesAt` in
`pkg/gpu/mocknvml/engine/engine.go` (~line 690-725): it stats
`/dev/nvidia<minor>` for every configured device and filters unless all or none
exist. `/dev/nvidia0` from the L4 makes it "1 of 8". Staged tree was correct
(`/var/lib/nvml-mock/driver/dev/nvidia0..7`, `config.yaml` `num_devices: 8`).

Falsifying experiment on worker7 only (`rm` the leaked nodes from that kind
node's private `/dev` tmpfs, delete its DRA plugin pod):

```
$ docker exec mokka-hetero-worker7 sh -c "rm -rf /dev/nvidia0 /dev/nvidiactl /dev/nvidia-modeset /dev/nvidia-uvm /dev/nvidia-uvm-tools /dev/nvidia-caps; ls -la /dev/nvidia*"
ls: cannot access '/dev/nvidia*': No such file or directory
GPU 0..3: NVIDIA Graphics Device (UUID: GPU-307f0000-...-000000000000 .. 003)
pod/dra-driver-nvidia-gpu-kubelet-plugin-k2d2t condition met
00000-gpu.nvidia.com-mokka-hetero-worker7-8b4xv	4	gpu-0,gpu-3,gpu-1,gpu-2
```

Applied to all 10 nodes with `scripts/s3b-hide-host-gpu.sh --restart`
(idempotent: removes the leaked nodes in every kind node, then rollout-restarts
the three nvml-mock DaemonSets and the DRA kubelet-plugin DaemonSet so no pod
keeps a stale `/dev` copy). Log `logs/s3b-hide-host-gpu.log`, rc=0:

```
mokka-hetero-control-plane remaining /dev/nvidia* entries: 0
mokka-hetero-worker remaining /dev/nvidia* entries: 0
... (all 10 nodes: 0)
daemon set "nvml-mock-h100" successfully rolled out
daemon set "nvml-mock-gb300" successfully rolled out
daemon set "nvml-mock-vr200" successfully rolled out
daemon set "dra-driver-nvidia-gpu-kubelet-plugin" successfully rolled out
DONE
```

Pre-fix plugin log: `/tmp/mokka-hetero-58fc971e/h1/dra-plugin-worker-before-fix.log`.

#### When `s3b-hide-host-gpu.sh --restart` has to be re-run

Docker copies the host's GPU nodes into a privileged container's `/dev` every
time that container starts. The experiment below used a throwaway container from
the same kind node image and did not touch the cluster:

```
$ docker run --rm --privileged --entrypoint sh kindest/node:v1.36.1@sha256:3489c767... -c "ls -la /dev/nvidia*"
crw-rw-rw- 1 root root 195, 254 Sep 23 10:44 /dev/nvidia-modeset
crw-rw-rw- 1 root root 510,   0 Sep 23 10:44 /dev/nvidia-uvm
crw-rw-rw- 1 root root 510,   1 Sep 23 10:44 /dev/nvidia-uvm-tools
crw-rw-rw- 1 root root 195,   0 Sep 23 10:44 /dev/nvidia0
crw-rw-rw- 1 root root 195, 255 Sep 23 10:44 /dev/nvidiactl
rc=0
$ docker run --rm --entrypoint sh kindest/node:v1.36.1@sha256:3489c767... -c "ls /dev/nvidia*"     (unprivileged control)
ls: cannot access '/dev/nvidia*': No such file or directory
```

Re-run it with `--restart` whenever a kind node container STARTS:
- after `docker restart`/`docker start` of any mokka-hetero node;
- after the Docker daemon restarts, or the VM reboots;
- after `kind create cluster` (a new or recreated cluster on this VM).

Any pod that was started on a node while its `/dev` still had the leak keeps its
own copy. `--restart` restarts the three nvml-mock DaemonSets and the DRA
kubelet-plugin DaemonSet. Any other privileged workload pod created during the
leak window must be deleted by hand. Two ways to detect the leak:
`docker exec <node> sh -c 'ls -d /dev/nvidia* 2>/dev/null | wc -l'` must print
0, and `scripts/s7-verify.sh` goes RED with `devices=1` on every worker. Pods
created after the fix inherit the node's clean `/dev` and need nothing.

## Step 4: image load (DONE)

`scripts/s4-load.sh`: `kind load docker-image nvml-mock:hetero mokka-control-plane:hetero --name mokka-hetero`, rc=0 at 10:12:40Z; `crictl images` on every one of the 10 nodes lists
`docker.io/library/mokka-control-plane:hetero 9afd677bfb886 15.3MB` and
`docker.io/library/nvml-mock:hetero 9c496bb053f63 92.2MB`.

## Step 5: Mokka (DONE, no collision)

`scripts/s5-mokka.sh`. CRDs: `helm upgrade --install mokka-crds deployments/mokka-crds/helm/mokka-crds` (namespace default). Three releases in namespace `mokka`,
each `--set gpu.profile=<p> --set nodeSelector.nvml-mock/profile=<p> --set image.repository=nvml-mock --set image.tag=hetero --set image.pullPolicy=Never --wait --timeout 300s`
(`gpu.count` left empty so the profile decides). Control plane on
`nvml-mock-h100` ONLY: `controlPlane.enabled=true`,
`controlPlane.image.repository=mokka-control-plane`, `controlPlane.image.tag=hetero`,
`controlPlane.image.allowMutableTag=true` (required: the template demands a
digest unless this is true, `templates/controlplane/deployment.yaml:3-8`),
`controlPlane.image.pullPolicy=Never`.

```
mokka-crds rc=0
helm install nvml-mock-h100 rc=0 2026-09-23T10:13:02Z
helm install nvml-mock-gb300 rc=0 2026-09-23T10:13:15Z
helm install nvml-mock-vr200 rc=0 2026-09-23T10:13:27Z
NAME           	NAMESPACE	REVISION	STATUS  	CHART              	APP VERSION
mokka-crds     	default  	1       	deployed	mokka-crds-0.4.0   	0.4.0
nvml-mock-gb300	mokka    	1       	deployed	nvml-mock-0.4.0-rc1	550.163.01
nvml-mock-h100 	mokka    	1       	deployed	nvml-mock-0.4.0-rc1	550.163.01
nvml-mock-vr200	mokka    	1       	deployed	nvml-mock-0.4.0-rc1	550.163.01
daemonset.apps/nvml-mock-gb300   3 3 3 3 3   nvml-mock/profile=gb300
daemonset.apps/nvml-mock-h100    3 3 3 3 3   nvml-mock/profile=h100
daemonset.apps/nvml-mock-vr200   3 3 3 3 3   nvml-mock/profile=vr200
deployment.apps/nvml-mock-h100-control-plane   1/1   mokka-control-plane:hetero
```

Why the three releases do not collide: cluster-scoped objects exist only in the
control-plane templates, and only one release renders them:

```
$ helm get manifest <release> | grep "^kind:" | sort | uniq -c
== nvml-mock-h100: ClusterRole 1, ClusterRoleBinding 1, ConfigMap 1, DaemonSet 1, Deployment 1, NetworkPolicy 1, Role 1, RoleBinding 1, Service 2, ServiceAccount 2, ValidatingAdmissionPolicy 1, ValidatingAdmissionPolicyBinding 1
== nvml-mock-gb300: ConfigMap 1, DaemonSet 1, NetworkPolicy 1, Service 1, ServiceAccount 1
== nvml-mock-vr200: ConfigMap 1, DaemonSet 1, NetworkPolicy 1, Service 1, ServiceAccount 1
```

Control plane holds the leader lease:

```
{"level":"info","time":"2026-09-23T10:12:51.883Z","msg":"http server listening","addr":"[::]:8080"}
"Successfully acquired lease" lock="mokka/control-plane.mokka.nvidia.com"
$ kubectl -n mokka get lease
control-plane.mokka.nvidia.com   nvml-mock-h100-control-plane-6df546f988-t44b9_...
$ kubectl get sgpuinventories,sgpuracks,sgpurackprofiles
No resources found
```

Cosmetic: chart NOTES print "Mock GPU environment deployed on all nodes!" even
with a nodeSelector.

## Step 6: DRA driver 0.5.0 (DONE)

`scripts/s6-dra.sh`: the guide's Step 3 command verbatim (`--version 0.5.0
--namespace nvidia --create-namespace --set nvidiaDriverRoot=/var/lib/nvml-mock/driver
--set gpuResourcesEnabledOverride=true --set resources.computeDomains.enabled=false`),
only `--timeout 300s` instead of 180s. Device plugin NOT installed.

```
helm install dra rc=0 2026-09-23T10:14:05Z
dra-driver-nvidia-gpu-kubelet-plugin-*   1/1 Running   (9 pods, one per worker 1-9; none on the control plane)
wait rc=0
```

Plugin image `nvcr.io/nvidia/dra-driver-nvidia-gpu:v0.5.0`, commit
`90b3a5917f0cbeb73a3c669e1e63690f89d0f437` (from its log). Harmless noise in
its log: `rpc error: code = Unimplemented desc = device health reporting is not
supported by this driver` every 5s (kubelet 1.36 health-watch probe).

## Step 7: verification (DONE, gate PASSES after the Step 3b fix)

`scripts/s7-verify.sh` exits non-zero if any worker's device count differs from
its profile (h100 8, gb300/vr200 4), if the control plane is not Running/ready,
or if the 4 Mokka CRDs are missing. It went RED first (1 device per node, see
3b), so the gate discriminates. Final run (log copied back to
`/tmp/mokka-hetero-58fc971e/h1/s7-verify.log`):

```
verify rc=0
== kubectl get nodes -L nvml-mock/profile
NAME                         STATUS   ROLES           AGE     VERSION   PROFILE
mokka-hetero-control-plane   Ready    control-plane   7m14s   v1.36.1
mokka-hetero-worker          Ready    <none>          7m      v1.36.1   h100
mokka-hetero-worker2         Ready    <none>          6m59s   v1.36.1   h100
mokka-hetero-worker3         Ready    <none>          6m59s   v1.36.1   h100
mokka-hetero-worker4         Ready    <none>          7m1s    v1.36.1   gb300
mokka-hetero-worker5         Ready    <none>          7m      v1.36.1   gb300
mokka-hetero-worker6         Ready    <none>          6m59s   v1.36.1   gb300
mokka-hetero-worker7         Ready    <none>          6m59s   v1.36.1   vr200
mokka-hetero-worker8         Ready    <none>          7m      v1.36.1   vr200
mokka-hetero-worker9         Ready    <none>          7m      v1.36.1   vr200
== kubectl get resourceslices -o wide
NAME                                              NODE                   DRIVER           POOL                   AGE
00000-gpu.nvidia.com-mokka-hetero-worker-hc2jp    mokka-hetero-worker    gpu.nvidia.com   mokka-hetero-worker    4m22s
00000-gpu.nvidia.com-mokka-hetero-worker2-qkdv4   mokka-hetero-worker2   gpu.nvidia.com   mokka-hetero-worker2   4m22s
00000-gpu.nvidia.com-mokka-hetero-worker3-kpp5g   mokka-hetero-worker3   gpu.nvidia.com   mokka-hetero-worker3   4m22s
00000-gpu.nvidia.com-mokka-hetero-worker4-q6m2r   mokka-hetero-worker4   gpu.nvidia.com   mokka-hetero-worker4   4m23s
00000-gpu.nvidia.com-mokka-hetero-worker5-2ss7d   mokka-hetero-worker5   gpu.nvidia.com   mokka-hetero-worker5   4m23s
00000-gpu.nvidia.com-mokka-hetero-worker6-lm2zh   mokka-hetero-worker6   gpu.nvidia.com   mokka-hetero-worker6   4m23s
00000-gpu.nvidia.com-mokka-hetero-worker7-8b4xv   mokka-hetero-worker7   gpu.nvidia.com   mokka-hetero-worker7   4m23s
00000-gpu.nvidia.com-mokka-hetero-worker8-k4j2d   mokka-hetero-worker8   gpu.nvidia.com   mokka-hetero-worker8   4m22s
00000-gpu.nvidia.com-mokka-hetero-worker9-j5krf   mokka-hetero-worker9   gpu.nvidia.com   mokka-hetero-worker9   4m22s
== expected vs actual per worker
PASS mokka-hetero-worker profile=h100 devices=8
PASS mokka-hetero-worker2 profile=h100 devices=8
PASS mokka-hetero-worker3 profile=h100 devices=8
PASS mokka-hetero-worker4 profile=gb300 devices=4
PASS mokka-hetero-worker5 profile=gb300 devices=4
PASS mokka-hetero-worker6 profile=gb300 devices=4
PASS mokka-hetero-worker7 profile=vr200 devices=4
PASS mokka-hetero-worker8 profile=vr200 devices=4
PASS mokka-hetero-worker9 profile=vr200 devices=4
== Mokka control plane
pod/nvml-mock-h100-control-plane-6df546f988-t44b9   1/1     Running   0   5m38s   mokka-hetero-worker7
control-plane phase/ready: Running/true
== kubectl get crd | grep mokka
sgpuinventories.mokka.nvidia.com           2026-09-23T10:12:49Z
sgpurackprofiles.mokka.nvidia.com          2026-09-23T10:12:49Z
sgpuracks.mokka.nvidia.com                 2026-09-23T10:12:49Z
sgpuruntimepolicies.mokka.nvidia.com       2026-09-23T10:12:49Z
VERIFY fail=0
```

Totals: 3x8 + 6x4 = 48 devices on the real tier, one slice per node, one pool
per node (pool name = node name), `resourceSliceCount: 1`, `generation: 1`.

### ResourceSlice identity per type

Full dumps: `/tmp/mokka-hetero-58fc971e/h1/resourceslice-{h100,gb300,vr200}.yaml`
(and `.json`; all 9 slices in `resourceslices-all.json`). Nodes: h100 =
mokka-hetero-worker, gb300 = mokka-hetero-worker4, vr200 = mokka-hetero-worker7.
Tabulated with jq over every device in each slice (value shown once when all
devices agree):

| attribute (driver gpu.nvidia.com) | h100 | gb300 | vr200 |
|---|---|---|---|
| productName (string) | NVIDIA H100 80GB HBM3 | NVIDIA GB300 NVL | NVIDIA Graphics Device |
| architecture (string) | Hopper | Blackwell | Rubin |
| cudaComputeCapability (version) | 9.0.0 | 10.0.0 | 10.7.0 |
| capacity memory | 80Gi | 288Gi | 288Gi |
| driverVersion (version) | 550.163.1 | 570.124.6 | 615.23.0 |
| cudaDriverVersion (version) | 12.4.0 | 12.8.0 | 13.4.0 |
| brand (string) | Nvidia | Nvidia | Nvidia |
| type (string) | gpu | gpu | gpu |
| uuid (string) | per device, GPU-01000100-0000-0000-0000-00000000000{0..7} | per device, GPU-b300b300-0000-0000-0000-00000000000{0..3} | per device, GPU-307f0000-0000-0000-0000-00000000000{0..3} |
| resource.kubernetes.io/pciBusID (string) | per device, 0000:1a/1b/4a/4b/8a/8b/ca/cb:00.0 | per device, 0000:0a/0b/4a/4b:00.0 | per device, 0002:81, 0002:c1, 000a:81, 000a:e1 (:00.0) |
| device count | 8 | 4 | 4 |

Every device has exactly the keys `attributes, capacity, name`; the attribute
set is the same 9 keys for all three types; `capacity` has only `memory`.

Observations (findings, not blockers):
- VR200 differs from GB300 on productName, architecture and compute capability
  (SPEC D1 requirement holds); memory is equal (288Gi).
- VR200 productName is `NVIDIA Graphics Device`: that is the profile's `name`
  (`profiles/vr200.yaml:48`, commented as the pre-release string real silicon
  reports). A CEL selector on productName alone cannot name "VR200".
- GB300 compute capability is published as 10.0.0 (SPEC known unknown: real GB300
  may be 10.3). This is what the stack believes.
- driverVersion is semver-normalised: `550.163.01` becomes `550.163.1`,
  `570.124.06` becomes `570.124.6`.
- Device names are `gpu-<minor>`, not `gpu-<index>`: on vr200, index 1 has
  `minor_number: 3` (`profiles/vr200.yaml` devices list), and the slice maps
  `gpu-3 -> uuid ...001, pci 0002:c1:00.0`.
- UUIDs and PCI bus IDs are identical across the 3 nodes of a type (e.g. all
  three h100 slices carry GPU-01000100-...-000 for gpu-0). Uniqueness is only
  per node in the real tier today; relevant to H2's clone procedure.
- No PCIe root / NUMA attribute: the plugin logs `error getting PCIe root for
  device 0, continuing without attribute ... readlink /sys/bus/pci/devices/0000:1a:00.0: no such file or directory`.

## Step 8: vLLM image

Pull (DONE): `scripts/s8-pull-vllm.sh`:

```
[vllm/vllm-openai:v0.30.0] sha256:8a69ffad015f138d7170c4ddc429e230a3bc1c1719f67e14324749df200a4b90 amd64 [vllm/vllm-openai@sha256:8a69ffad015f138d7170c4ddc429e230a3bc1c1719f67e14324749df200a4b90] 30729844140
DONE rc=0
$ docker images
vllm/vllm-openai:v0.30.0   8a69ffad015f   30.7GB   8.73GB
```

Load into one worker per type (DONE): `scripts/s8-load-vllm.sh`, nodes
mokka-hetero-worker (h100), mokka-hetero-worker4 (gb300), mokka-hetero-worker7
(vr200). The command from the brief failed first, and the brief's own fallback worked:

```
kind load docker-image vllm/vllm-openai:v0.30.0 --name mokka-hetero --nodes mokka-hetero-worker,mokka-hetero-worker4,mokka-hetero-worker7
ERROR: failed to load image: command "docker exec --privileged -i mokka-hetero-worker7 ctr --namespace=k8s.io images import --all-platforms --digests --snapshotter=overlayfs -" failed with error: exit status 1
Command Output: ctr: content digest sha256:4864d46625cbc3307623e29ac742030655e27249feba7b97ec925ce4cc4dfb56: not found
kind load docker-image rc=1 2026-09-23T10:26:52Z
fallback: docker save --platform linux/amd64 + kind load image-archive
docker save rc=0
kind load image-archive rc=0 2026-09-23T10:39:48Z
== mokka-hetero-worker
docker.io/vllm/vllm-openai   v0.30.0   609d7adfa7455   d076d77d8dade   8.73GB
== mokka-hetero-worker4
docker.io/vllm/vllm-openai   v0.30.0   609d7adfa7455   d076d77d8dade   8.73GB
== mokka-hetero-worker7
docker.io/vllm/vllm-openai   v0.30.0   609d7adfa7455   d076d77d8dade   8.73GB
DONE rc=0
```

The missing digest is the arm64 manifest: the image is a multi-arch index, only
amd64 was pulled, and `ctr import --all-platforms` expects every platform. This is
the same failure recorded in project memory for Docker's containerd image
store. Full digests (`ctr -n k8s.io images ls`, and the registry index):

```
mokka-hetero-worker:  docker.io/vllm/vllm-openai:v0.30.0 sha256:5f5e535216848d0c52159c8c13a0af04be5f6fe1a84e79914300610796f76d40 8.1GiB
mokka-hetero-worker4: docker.io/vllm/vllm-openai:v0.30.0 sha256:5f5e535216848d0c52159c8c13a0af04be5f6fe1a84e79914300610796f76d40 8.1GiB
mokka-hetero-worker7: docker.io/vllm/vllm-openai:v0.30.0 sha256:5f5e535216848d0c52159c8c13a0af04be5f6fe1a84e79914300610796f76d40 8.1GiB
(the other 7 nodes: no vllm image)
$ docker buildx imagetools inspect vllm/vllm-openai:v0.30.0
Digest:    sha256:8a69ffad015f138d7170c4ddc429e230a3bc1c1719f67e14324749df200a4b90   (index)
  ...@sha256:4864d46625cbc3307623e29ac742030655e27249feba7b97ec925ce4cc4dfb56   linux/arm64
  ...@sha256:5f5e535216848d0c52159c8c13a0af04be5f6fe1a84e79914300610796f76d40   linux/amd64
$ docker exec mokka-hetero-worker7 crictl inspecti vllm/vllm-openai:v0.30.0 | jq -r '.status.id, .status.repoDigests[]?, .status.size'
sha256:d076d77d8dade699041dbcb6bb989a058e51b532e6367f13f80b5a4e63ee5c53
docker.io/library/import-2026-09-23@sha256:609d7adfa7455d495f6e8a4ef1eec32542abe91c76cf8a821405ee1c513eb284
8730576791
```

The node image is the registry's linux/amd64 manifest `sha256:5f5e5352...`. Wave-2
pods must reference it by tag (`vllm/vllm-openai:v0.30.0`) with
`imagePullPolicy: Never` or `IfNotPresent` and a nodeSelector for these three
nodes. CRI's repoDigest is a `library/import-...` artefact of the archive import, so
a pin by `@sha256:8a69...` (the index) would not resolve locally. INFERENCE:
that follows from the repoDigest shown; I did not test pulling by digest.

## Step 9: snapshot (DONE)

`scripts/s9-snapshot.sh` at 10:40:12Z, just after the 3x vLLM import finished
(log `/tmp/mokka-hetero-58fc971e/h1/s9-snapshot.log`):

```
== nproc / load
4
 10:40:12 up 13 days, 23:36,  1 user,  load average: 7.78, 13.06, 11.49
== free -m
               total        used        free      shared  buff/cache   available
Mem:           15363        4280         227          60       11268       11083
Swap:           3924        1131        2793
== df -h /
/dev/root       290G  182G  109G  63% /
== docker stats --no-stream
mokka-hetero-worker          1.73%   526.6MiB / 15GiB
mokka-hetero-worker7         3.45%   651MiB / 15GiB
mokka-hetero-control-plane  16.68%   753.5MiB / 15GiB
mokka-hetero-worker8         2.05%   193.9MiB / 15GiB
mokka-hetero-worker2         2.08%   202.3MiB / 15GiB
mokka-hetero-worker4         2.68%   497.4MiB / 15GiB
mokka-hetero-worker3         2.45%   190.8MiB / 15GiB
mokka-hetero-worker6         2.00%   193.1MiB / 15GiB
mokka-hetero-worker5         1.84%   179.9MiB / 15GiB
mokka-hetero-worker9         2.84%   175.7MiB / 15GiB
== summed kind node memory (MiB)
3571 MiB across 10 containers
== docker system df
Images          4         1         32.49GB   31.17GB (95%)
Local Volumes   10        10        105GB     0B (0%)
Build Cache     63        0         6.335GB   5.893GB
== pods not Running/Completed
(none)
== pod count
46
```

Steady state two minutes later: `10:42:22 up 13 days, 23:38, load average: 2.93, 9.10, 10.22`.
The three vLLM-loaded nodes use more memory than the others (worker, worker4,
worker7 ~500-650 MiB against ~180-200 MiB). INFERENCE: that is page cache from the
import, charged to their cgroups. About 11 GB of RAM remain available for KWOK
and wave 2. Disk has 109 GB free: each vLLM-loaded node holds about 25-40 GB,
and the VM's Docker still keeps the 30.7 GB vLLM image (reclaimable).

## Final-state verification (re-run after steps 8-9)

```
$ bash ~/mokka-hetero/scripts/s7-verify.sh     (log s7-verify-final.log)
verify rc=0
PASS mokka-hetero-worker profile=h100 devices=8
PASS mokka-hetero-worker2 profile=h100 devices=8
PASS mokka-hetero-worker3 profile=h100 devices=8
PASS mokka-hetero-worker4 profile=gb300 devices=4
PASS mokka-hetero-worker5 profile=gb300 devices=4
PASS mokka-hetero-worker6 profile=gb300 devices=4
PASS mokka-hetero-worker7 profile=vr200 devices=4
PASS mokka-hetero-worker8 profile=vr200 devices=4
PASS mokka-hetero-worker9 profile=vr200 devices=4
control-plane phase/ready: Running/true
VERIFY fail=0
$ for n in $(kind get nodes --name mokka-hetero); do docker exec $n sh -c 'ls -d /dev/nvidia* 2>/dev/null | wc -l'; done
0 on all 10 nodes
$ kubectl get pods -A --no-headers | awk '{print $4}' | sort | uniq -c
     46 Running
```

## Concerns (for the chief)

1. **The real L4 leaks into kind (fixed, but the fix does not survive a node restart).** Details
   in Step 3b. The fix is `scripts/s3b-hide-host-gpu.sh --restart`. It must be re-run
   whenever a kind node container starts: a node restart, a Docker daemon restart,
   a VM reboot, or a new `kind create cluster`. See "When ... has to be re-run" in
   Step 3b; the privileged-container experiment there backs this. The KWOK tier is
   unaffected: it runs no containers.
2. **Real GPU reachable through mock device nodes (INFERENCE, not tested).** The
   mock stages `/var/lib/nvml-mock/driver/dev/nvidia0..N` as `195:N`, `nvidiactl` as `195:255` and `nvidia-uvm` as `510:0`.
   Those are the same majors and minors the host's real driver serves
   (`/proc/devices`: `195 nvidia`, `510 nvidia-uvm`). The staged CDI spec
   `/var/run/cdi/nvidia.yaml` injects them into containers. A pod that also loads
   a real user-mode libcuda (for example a cuda-compat libcuda in the vLLM image) could
   therefore open the physical L4 (host kernel module 595.71.05).
   Chief's assessment (INFERENCE): the vLLM compat libcuda is older than the kernel
   module, so cuInit should fail with a driver mismatch instead of reaching the L4.
   Wave 2 will measure this. I have no cuInit evidence either way, because H1 ran no CUDA. I
   did confirm the version premise by listing files only (nothing was executed
   against a GPU):
   ```
   $ docker run --rm --entrypoint sh vllm/vllm-openai:v0.30.0 -c "ls -la /usr/local/cuda/compat/"
   libcuda.so.1 -> libcuda.so.580.95.05
   -rw-r--r-- 1 root root 96276264 Sep 23  2025 libcuda.so.580.95.05
   (also /usr/local/cuda-13.0/compat: libcuda.so, libcuda.so.1)
   ```
   The nvml-mock CDI spec `/var/run/cdi/nvidia.yaml` mounts `libnvidia-ml.so.1`
   but no libcuda. The DRA driver's own per-claim CDI spec does not exist yet:
   `/var/run/cdi` on worker7 held only `nvidia.yaml` and `nvml-mock-nri.yaml`,
   because no claim has been prepared. So what the DRA path injects into a pod is
   unmeasured.
3. **Leftover daemon on the "cleaned" VM.** `~/pause-injector.sh`
   (PID 1562324, started Sep 13) looped over every `^mokka-` container, so it hit our
   nodes too. It left a `ctr images import` in mokka-hetero-worker4 hung since
   10:13:33Z. I reported it to main mid-task and did NOT kill it myself. The chief
   then stopped it and its hung import (PIDs 1269825, 1269855). Per the chief it was an
   orphan of a Sep 13 Teleport session with parent PID 1, no systemd unit and no cron entry, so
   it will not come back. The script file stays on disk. My own check at 10:42Z
   agrees: `pgrep -af pause-injector` and `pgrep -af "ctr -n k8s.io images import"`
   each matched only the pgrep itself. RESOLVED.
4. **Identity facts that matter for the selectors and the clone procedure (H2 / S1).** VR200 productName is
   `NVIDIA Graphics Device`. GB300 CC is 10.0.0. driverVersion is semver-normalised.
   Device names are `gpu-<minor>`. UUIDs and PCI bus IDs repeat across the nodes of a
   type. See the table in Step 7.
5. `kind load docker-image` cannot load the multi-arch vLLM image from this
   Docker. Use `docker save --platform linux/amd64` + `kind load image-archive`.

## Status

DONE_WITH_CONCERNS. The real tier is up and passes its gate: 1 control plane + 9
workers, 48 DRA devices (8/8/8 h100, 4/4/4 gb300, 4/4/4 vr200), Mokka CRDs, three
nvml-mock releases, one control plane holding the lease, DRA driver 0.5.0.
The vLLM image is on one worker per type. Concerns 1-2 carry into wave 2.
