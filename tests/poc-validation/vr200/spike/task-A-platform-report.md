# Task A report: Mokka vr200 kind cluster (mokka-vr200-llm)

Status: DONE_WITH_CONCERNS

The cluster is up. Each of the 3 workers advertises `nvidia.com/gpu: 4` (vr200). The
track labels and namespaces are in place, and the pre-pulls are running in the background.

Concerns, details below:

1. **Following the device-plugin guide exactly does not put `nvidia-smi` or
   `libnvidia-ml.so` into a GPU pod.** The pod gets only `/dev/nvidia0..3`
   and `NVIDIA_VISIBLE_DEVICES`. Wave-1 pods need the hostPath recipe in
   section 6.3. Tested: stock debian runs mock `nvidia-smi` with it.
2. **Docker VM memory is tight.** 4.7 GB is available and 1 GB of swap is
   fully used, shared with 4 other kind clusters. Three engine pods (torch
   import) running at once may OOM.
3. **The first pull attempt was aborted.** It saturated the link and starved the
   image build: apt got about 48 KB/s. I stopped it and relaunched it after
   verification (step 8). That cost about 5 minutes of pull time.
4. **A brief premise is false on this branch.** No `ghcr.io/nvidia/mokka-kind-node`
   reference exists. I used kind's default node image (section 2).

Scratch dir: `/tmp/vr200-llm-spike-58fc971e/`. Every Task A file there starts with
`a-`, and every step has a script plus a log.

---

## Step 1: build the nvml-mock image

Script `a-step1-build.sh`, log `a-step1-build.log`.

```
$ git -C <repo>/.worktrees/spike-vr200-llm rev-parse HEAD
8058e1c9fe1ed278357b820094fe2b22170804c1

$ cd .../.worktrees/spike-vr200-llm && docker build -t nvml-mock:vr200-spike -f deployments/nvml-mock/Dockerfile .
...
#35 exporting manifest list sha256:2ba3bdee407d63e3118651b7b45997bd312dbb5619be2ce9267985b02e6fb6d4 done
#35 naming to docker.io/library/nvml-mock:vr200-spike done
#35 DONE 4.1s
BUILD_RC=0

$ docker image inspect nvml-mock:vr200-spike --format 'ID={{.Id}} Arch={{.Architecture}} Os={{.Os}} Created={{.Created}} Size={{.Size}}'
ID=sha256:2ba3bdee407d63e3118651b7b45997bd312dbb5619be2ce9267985b02e6fb6d4 Arch=arm64 Os=linux Created=2026-09-23T05:44:33.251339463Z Size=88596550
```

**Image ID (host): `sha256:2ba3bdee407d63e3118651b7b45997bd312dbb5619be2ce9267985b02e6fb6d4`**
(the manifest-list digest, because Docker Desktop uses the containerd image store). Inside
the kind nodes, `crictl images` shows the platform image ID `ba14edd557b2d`
(88.6 MB); see step 3.

## Step 2: create the cluster

### Node image decision

The brief says README "Quick start" uses `ghcr.io/nvidia/mokka-kind-node:latest`.
That string appears nowhere on this branch. The search below could have found it,
because the same command finds `kindest/node`:

```
$ grep -rIl 'mokka-kind-node' <worktree> --exclude-dir=vendor --exclude-dir=.git; echo rc=$?
rc=1
$ grep -rIl 'kindest/node' <worktree> --exclude-dir=vendor --exclude-dir=.git | head
.../tests/e2e/go/scenario_nri_test.go
.../docs/helm-chart.md
.../docs/guides/nv-sentinel/run.sh
.../.github/workflows/nvml-mock-e2e-go.yaml
.../enhancements/meps/0002-device-plugin-nri-composition/README.md
.../deployments/kind-nvidia-cdi/Dockerfile
.../deployments/kind-nvidia-cdi/Makefile
.../deployments/kind-nvidia-cdi/containerd-config.toml
```

On this branch, README Quick start is `kind create cluster --name mokka` and
docs/guides/device-plugin.md Step 1 is `kind create cluster --name mokka-device-plugin`.
Neither pins an image. I followed the device-plugin guide, so the cluster uses
kind's built-in default. kind v0.33.0 resolved that to **`kindest/node:v1.37.0`**
(containerd 2.3.4). The image contains no NVIDIA runtime and no toolkit.

Tools: `kind v0.33.0 go1.27.0 darwin/arm64`, kubectl client v1.36.1, helm v4.3.0,
Docker 29.6.2 arm64.

### Kind config (`/tmp/vr200-llm-spike-58fc971e/a-kind-config.yaml`)

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
  - role: worker
  - role: worker
```

The shape matches docs/guides/kind.yaml, minus its `run.ai/simulated-gpu-node-pool`
labels, which belong to the Run:ai FGO guide.

### Create (script `a-step2-create.sh`, log `a-step2-create.log`)

```
$ kind create cluster --name mokka-vr200-llm --config /tmp/vr200-llm-spike-58fc971e/a-kind-config.yaml --wait 180s
Creating cluster "mokka-vr200-llm" ...
 ✓ Ensuring node image (kindest/node:v1.37.0)
 ✓ Preparing nodes
 ✓ Writing configuration
 ✓ Starting control-plane
 ✓ Installing CNI
 ✓ Installing StorageClass
 ✓ Joining worker nodes
 • Ready after 10s
Set kubectl context to "kind-mokka-vr200-llm"
CREATE_RC=0
```

kind switched current-context to the new cluster. Before the create,
current-context was unset (`kubectl config current-context` printed nothing), so I
put it back with `kubectl config unset current-context`. Every command in this report
passes `--context kind-mokka-vr200-llm` / `--kube-context kind-mokka-vr200-llm`.

```
$ kubectl --context kind-mokka-vr200-llm get nodes -o wide
NAME                            STATUS   ROLES           VERSION   INTERNAL-IP   OS-IMAGE                       KERNEL-VERSION             CONTAINER-RUNTIME
mokka-vr200-llm-control-plane   Ready    control-plane   v1.37.0   172.19.0.13   Debian GNU/Linux 13 (trixie)   6.12.76-linuxkit (arm64)   containerd://2.3.4
mokka-vr200-llm-worker          Ready    <none>          v1.37.0   172.19.0.12   Debian GNU/Linux 13 (trixie)   6.12.76-linuxkit (arm64)   containerd://2.3.4
mokka-vr200-llm-worker2         Ready    <none>          v1.37.0   172.19.0.11   Debian GNU/Linux 13 (trixie)   6.12.76-linuxkit (arm64)   containerd://2.3.4
mokka-vr200-llm-worker3         Ready    <none>          v1.37.0   172.19.0.14   Debian GNU/Linux 13 (trixie)   6.12.76-linuxkit (arm64)   containerd://2.3.4
```

Effective containerd config on a worker:

```
$ docker exec mokka-vr200-llm-worker bash -c 'containerd config dump | grep -n -i -E "enable_cdi|cdi_spec_dirs|default_runtime_name|runtimes\.[a-z]+\]"'
51:    enable_cdi = true
52:    cdi_spec_dirs = ['/etc/cdi', '/var/run/cdi']
61:      default_runtime_name = 'runc'
66:        [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc]
$ ... containerd config dump | sed -n 168,170p
  [plugins.'io.containerd.nri.v1.nri']
    disable = false
    socket_path = '/var/run/nri/nri.sock'
$ docker exec mokka-vr200-llm-worker bash -c 'ls /usr/bin | grep -i nvidia; echo rc=$?'
rc=1
$ docker exec mokka-vr200-llm-worker ls /usr/bin/nvidia-cdi-hook
ls: cannot access '/usr/bin/nvidia-cdi-hook': No such file or directory
```

The node has `runc` only, with no nvidia runtime handler. CDI is on and NRI is on.

## Step 3: kind load (script `a-step3-load.sh`, log `a-step3-load.log`)

```
$ kind load docker-image nvml-mock:vr200-spike --name mokka-vr200-llm
Image: "nvml-mock:vr200-spike" with ID "sha256:2ba3bdee..." not yet present on node "mokka-vr200-llm-worker2", loading...
Image: "nvml-mock:vr200-spike" with ID "sha256:2ba3bdee..." not yet present on node "mokka-vr200-llm-control-plane", loading...
Image: "nvml-mock:vr200-spike" with ID "sha256:2ba3bdee..." not yet present on node "mokka-vr200-llm-worker", loading...
Image: "nvml-mock:vr200-spike" with ID "sha256:2ba3bdee..." not yet present on node "mokka-vr200-llm-worker3", loading...
LOAD_RC=0
--- (each of the 4 nodes) docker exec <node> crictl images | grep nvml-mock
docker.io/library/nvml-mock                     vr200-spike          ba14edd557b2d       88.6MB
```

`kind load docker-image` worked on the first try. The `content digest not found`
fallback was not needed.

## Step 4: chart install (script `a-step4-install.sh`, log `a-step4-install.log`)

The chart is installed from the worktree, not from OCI. The image keys come from
values.yaml (`image.repository`, `image.tag`, `image.pullPolicy`). A local
`helm template` render (`a-helm-template.yaml`) confirmed
`image: "nvml-mock:vr200-spike"`, `imagePullPolicy: Never`, `GPU_COUNT=4`, and
`DRIVER_VERSION=615.23` before the install.

```
$ helm install nvml-mock <repo>/.worktrees/spike-vr200-llm/deployments/nvml-mock/helm/nvml-mock \
    --kube-context kind-mokka-vr200-llm \
    --namespace mokka --create-namespace \
    --set gpu.profile=vr200 \
    --set image.repository=nvml-mock \
    --set image.tag=vr200-spike \
    --set image.pullPolicy=Never \
    --wait --timeout 180s
NAME: nvml-mock
NAMESPACE: mokka
STATUS: deployed
REVISION: 1
NOTES:
  Profile: vr200
  GPUs per node: 4
  Driver version: 615.23
  Mock driver root: /var/lib/nvml-mock/driver
HELM_RC=0

daemonset.apps/nvml-mock   4   4   4   4   4   <none>   node-agent   nvml-mock:vr200-spike
pod/nvml-mock-255ww   1/1   Running   mokka-vr200-llm-worker2
pod/nvml-mock-j6z67   1/1   Running   mokka-vr200-llm-worker3
pod/nvml-mock-k2l7t   1/1   Running   mokka-vr200-llm-control-plane
pod/nvml-mock-zvrzf   1/1   Running   mokka-vr200-llm-worker
nvml-mock   mokka   1   deployed   nvml-mock-0.4.0-rc1   550.163.01
```

`nri.enabled` stays at its default of `false`, and so do all other values.

## Step 5: device plugin, as in docs/guides/device-plugin.md (script `a-step5-deviceplugin.sh`)

The manifest `a-device-plugin.yaml` is the guide's Step 3 heredoc, unchanged
(`nvcr.io/nvidia/k8s-device-plugin:v0.18.2`,
`--nvidia-driver-root=/var/lib/nvml-mock/driver`,
`--driver-root-ctr-path=/var/lib/nvml-mock/driver`,
`--device-discovery-strategy=nvml`, `--pass-device-specs=true`).
Proof that it matches, where the extract is 41 non-empty lines:

```
$ awk '<extract the kubectl apply heredoc>' docs/guides/device-plugin.md > a-device-plugin.guide-extract.yaml
$ grep -v '^# Verbatim' a-device-plugin.yaml | diff - a-device-plugin.guide-extract.yaml; echo diff-rc=$?
diff-rc=0
```

```
$ kubectl --context kind-mokka-vr200-llm label node --all mokka.nvidia.com/type=sgpu     # guide Step 2
node/mokka-vr200-llm-control-plane labeled
node/mokka-vr200-llm-worker labeled
node/mokka-vr200-llm-worker2 labeled
node/mokka-vr200-llm-worker3 labeled
$ kubectl --context kind-mokka-vr200-llm apply -f a-device-plugin.yaml
daemonset.apps/nvidia-device-plugin-mock created
$ kubectl --context kind-mokka-vr200-llm -n kube-system wait --for=condition=ready pod -l name=nvidia-device-plugin-mock --timeout=300s
pod/nvidia-device-plugin-mock-k6jh6 condition met
pod/nvidia-device-plugin-mock-nnq6w condition met
pod/nvidia-device-plugin-mock-pm64m condition met
pod/nvidia-device-plugin-mock-qplhc condition met
WAIT_RC=0
```

The one deviation from the guide is the wait timeout: 300s instead of 120s. It
leaves headroom for the image pull while the node was busy. Nothing else changed.

The device-plugin log on `mokka-vr200-llm-worker` shows the effective flags. The ones
that matter for step 6 are `deviceListStrategy: ["envvar"]` and `passDeviceSpecs: true`:

```
      "passDeviceSpecs": true,
      "deviceListStrategy": [
        "envvar"
      ],
      "deviceIDStrategy": "uuid",
I0923 05:45:53.526847  server.go:141] Starting to serve 'nvidia.com/gpu' on /var/lib/kubelet/device-plugins/nvidia-gpu.sock
I0923 05:45:53.530030  server.go:148] Registered device plugin for 'nvidia.com/gpu' with Kubelet
```

## Step 6: verification

### 6.1 Allocatable

```
$ kubectl --context kind-mokka-vr200-llm get nodes -o custom-columns='NODE:.metadata.name,GPUS:.status.allocatable.nvidia\.com/gpu,CAP:.status.capacity.nvidia\.com/gpu'
NODE                            GPUS   CAP
mokka-vr200-llm-control-plane   4      4
mokka-vr200-llm-worker          4      4
mokka-vr200-llm-worker2         4      4
mokka-vr200-llm-worker3         4      4
```

All 3 workers report 4. The control-plane also reports 4, because the guide labels
`--all`. It keeps its `NoSchedule` taint, so ordinary pods do not land there. My first
read, a few seconds after the plugin registered, showed `<none>` on the workers.
That was the kubelet node-status update lagging, and the next read at 05:46:00Z
showed 4.

### 6.2 The guide's gpu-pod (busybox:1.36), `nvidia.com/gpu: 4` on mokka-vr200-llm-worker

Manifest `a-gpu-pod-busybox.yaml`, script `a-step6a-busybox.sh`, log `a-step6a-busybox.log`.
The OCI spec is in `a-gpu-pod-busybox.crictl-inspect.json`.

```
$ kubectl --context kind-mokka-vr200-llm exec gpu-pod -- nvidia-smi -L
error: ... OCI runtime exec failed: exec failed: unable to start container process: exec: "nvidia-smi": executable file not found in $PATH
RC=1
$ kubectl ... exec gpu-pod -- nvidia-smi --query-gpu=name,memory.total,compute_cap,driver_version --format=csv
error: ... exec: "nvidia-smi": executable file not found in $PATH
RC=1
$ kubectl ... exec gpu-pod -- env
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
HOSTNAME=gpu-pod
NVIDIA_VISIBLE_DEVICES=GPU-307f0000-0000-0000-0000-000000000001,GPU-307f0000-0000-0000-0000-000000000002,GPU-307f0000-0000-0000-0000-000000000003,GPU-307f0000-0000-0000-0000-000000000000
(KUBERNETES_* omitted)
$ kubectl ... exec gpu-pod -- ls -l /dev
crw-rw-rw-    1 root     root      195,   0 Sep 23 05:46 nvidia0
crw-rw-rw-    1 root     root      195,   1 Sep 23 05:46 nvidia1
crw-rw-rw-    1 root     root      195,   2 Sep 23 05:46 nvidia2
crw-rw-rw-    1 root     root      195,   3 Sep 23 05:46 nvidia3
(no nvidiactl, no nvidia-uvm)
$ kubectl ... exec gpu-pod -- sh -c "mount | grep -i -E 'nvidia|nvml|cdi|lib64'; echo grep_rc=\$?"
grep_rc=1
$ kubectl ... exec gpu-pod -- sh -c "find / -xdev \( -name 'libnvidia-ml*' -o -name 'nvidia-smi' -o -name 'libcuda*' \) 2>/dev/null; echo find_rc=\$?"
find_rc=0            <- no output: none of the three exists
$ kubectl ... exec gpu-pod -- sh -c "find / -xdev -name 'busybox' 2>/dev/null"     <- positive control for that find
/bin/busybox
$ kubectl ... exec gpu-pod -- ls -l /usr/lib64/libnvidia-ml.so.1 /usr/bin/nvidia-smi /opt/nvml-mock
ls: /usr/lib64/libnvidia-ml.so.1: No such file or directory
ls: /usr/bin/nvidia-smi: No such file or directory
ls: /opt/nvml-mock: No such file or directory
```

The OCI spec (`crictl inspect`) confirms this. The container has 4 device entries,
no NVIDIA mounts, and no CDI devices. Its only hook is kind's own:

```
=== linux.devices
{"major":195,"minor":0,"path":"/dev/nvidia0","type":"c",...}
{"major":195,"minor":3,"path":"/dev/nvidia3","type":"c",...}
{"major":195,"minor":1,"path":"/dev/nvidia1","type":"c",...}
{"major":195,"minor":2,"path":"/dev/nvidia2","type":"c",...}
=== mounts: /proc /dev /dev/pts /dev/mqueue /sys /sys/fs/cgroup /etc/hosts /dev/termination-log
            /etc/hostname /etc/resolv.conf /dev/shm /var/run/secrets/kubernetes.io/serviceaccount
=== hooks
{"createContainer":[{"path":"/kind/bin/mount-product-files.sh"}]}
=== CDI devices: "no CDI_devices"
```

`kubectl describe pod gpu-pod` shows `Limits/Requests nvidia.com/gpu: 4`,
`Environment: <none>`, and only the service-account mount. The pod was deleted afterwards.

### 6.3 Arbitrary image with the mock driver added by hand (debian:bookworm-slim, `nvidia.com/gpu: 4`)

This is the pod wave-1 needs. It copies what the chart's NRI plugin would inject
(internal/nri/inject/adjust.go `mountOverlay` and env.go `setEnvironment`), but as
a hostPath volume and env vars in the pod spec, because the guide does not enable NRI.
Manifest `a-gpu-pod-manual.yaml`, script `a-step6b-manual.sh`, log `a-step6b-manual.log`:

```yaml
      env:
        - name: PATH
          value: /opt/nvml-mock/driver/usr/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
        - name: LD_LIBRARY_PATH
          value: /opt/nvml-mock/driver/usr/lib64
        - name: MOCK_NVML_CONFIG
          value: /opt/nvml-mock/driver/config/config.yaml
      resources:
        limits:
          nvidia.com/gpu: 4
      volumeMounts:
        - name: mock-root
          mountPath: /opt/nvml-mock
          readOnly: true
  volumes:
    - name: mock-root
      hostPath:
        path: /var/lib/nvml-mock
        type: Directory
```

```
$ kubectl ... exec gpu-pod-manual -- ls -l /usr/bin/nvidia-smi /usr/lib64/libnvidia-ml.so.1 /usr/lib/aarch64-linux-gnu/libnvidia-ml.so.1
ls: cannot access '/usr/bin/nvidia-smi': No such file or directory
ls: cannot access '/usr/lib64/libnvidia-ml.so.1': No such file or directory
ls: cannot access '/usr/lib/aarch64-linux-gnu/libnvidia-ml.so.1': No such file or directory
$ kubectl --context kind-mokka-vr200-llm exec gpu-pod-manual -- nvidia-smi -L
GPU 0: NVIDIA Graphics Device (UUID: GPU-307f0000-0000-0000-0000-000000000000)
GPU 1: NVIDIA Graphics Device (UUID: GPU-307f0000-0000-0000-0000-000000000001)
GPU 2: NVIDIA Graphics Device (UUID: GPU-307f0000-0000-0000-0000-000000000002)
GPU 3: NVIDIA Graphics Device (UUID: GPU-307f0000-0000-0000-0000-000000000003)
RC=0
$ kubectl --context kind-mokka-vr200-llm exec gpu-pod-manual -- nvidia-smi --query-gpu=name,memory.total,compute_cap,driver_version --format=csv
name, memory.total [MiB], compute_cap, driver_version
NVIDIA Graphics Device, 294912 MiB, 10.7, 615.23
NVIDIA Graphics Device, 294912 MiB, 10.7, 615.23
NVIDIA Graphics Device, 294912 MiB, 10.7, 615.23
NVIDIA Graphics Device, 294912 MiB, 10.7, 615.23
RC=0
$ kubectl ... exec gpu-pod-manual -- sh -c 'command -v nvidia-smi'
/opt/nvml-mock/driver/usr/bin/nvidia-smi
$ kubectl ... exec gpu-pod-manual -- mount | grep nvml
/dev/vda1 on /opt/nvml-mock type ext4 (ro,relatime,discard)
$ kubectl ... exec gpu-pod-manual -- ls -l /opt/nvml-mock/driver/usr/lib64/
libcuda.so -> libcuda.so.1
libcuda.so.1 -> libcuda.so.615.23
libcuda.so.615.23                    (2570280 bytes; the mock CUDA shim)
libcudart.so -> libcudart.so.12
libcudart.so.12 -> libcuda.so.1      (the shim, symlinked as the CUDA 12 runtime)
libnvidia-ml.so -> libnvidia-ml.so.1
libnvidia-ml.so.1 -> libnvidia-ml.so.615.23
libnvidia-ml.so.615.23               (14123928 bytes)
libibmad.so.5 libibnetdisc.so.5 libibumad.so.3 libibverbs.so.1 libnl-3.so.200 libnl-route-3.so.200
$ kubectl ... exec gpu-pod-manual -- ls -l /opt/nvml-mock/driver/usr/bin/
check-fabric iblinkinfo ibnetdiscover ibping ibstat ibstatus ibv_devinfo nvidia-smi nvidia-smi.sh sminfo
$ kubectl ... exec gpu-pod-manual -- ls -l /opt/nvml-mock/driver/config/
config.yaml  machine-type  overrides.yaml.lock
```

The profile matches the pinned facts: 288 GiB = 294912 MiB, compute cap 10.7,
driver 615.23. The pod was deleted afterwards.

### 6.4 A 1-GPU pod sees only its allocated GPU (log `a-step6c-subset.log`)

Same manifest with `nvidia.com/gpu: 1`:

```
$ kubectl ... exec gpu-pod-manual-1gpu -- nvidia-smi -L
GPU 0: NVIDIA Graphics Device (UUID: GPU-307f0000-0000-0000-0000-000000000003)
$ kubectl ... exec gpu-pod-manual-1gpu -- sh -c 'ls /dev/nvidia*; echo NVIDIA_VISIBLE_DEVICES=...'
/dev/nvidia2
NVIDIA_VISIBLE_DEVICES=GPU-307f0000-0000-0000-0000-000000000003
```

The device node is `/dev/nvidia2` while the UUID is `...003`. That is correct: vr200.yaml
deliberately maps index 3 to `minor_number: 2`, mirroring the hardware capture:

```
$ grep -n -E 'minor_number|uuid:|index:' .../profiles/vr200.yaml
441:  - index: 0 / 442: uuid "...000" / 446: minor_number: 0
451:  - index: 1 / 452: uuid "...001" / 456: minor_number: 3
461:  - index: 2 / 462: uuid "...002" / 466: minor_number: 1
471:  - index: 3 / 472: uuid "...003" / 476: minor_number: 2
```

The mock NVML decides which GPUs are visible by which `/dev/nvidia<N>` nodes exist in
the container, not by `NVIDIA_VISIBLE_DEVICES`
(pkg/gpu/mocknvml/engine/engine.go:683-723, `detectVisibleDevices` "by /dev/nvidia* presence").
When no `/dev/nvidia*` node exists, all GPUs are visible. Cleanup:

```
$ kubectl --context kind-mokka-vr200-llm get pods -n default
No resources found in default namespace.
```

### 6.5 How the mock driver reaches a GPU-requesting container (answer for wave 1)

| Channel | Used here? | Evidence |
|---|---|---|
| Device nodes `/dev/nvidia0..N` for the allocated GPUs only | **YES**, from the device plugin (`--pass-device-specs=true`) as OCI `linux.devices` | 6.2 OCI spec; 6.4 subset |
| `/dev/nvidiactl`, `/dev/nvidia-uvm`, `/dev/nvidia-uvm-tools` | **NO**. They exist on the node under `/var/lib/nvml-mock/driver/dev/` but the plugin does not pass them | 6.2 `ls -l /dev`; node `ls -l /var/lib/nvml-mock/driver/dev/` shows `nvidiactl (195,255)`, `nvidia-uvm (510,0)`, `nvidia-uvm-tools (510,1)` |
| `NVIDIA_VISIBLE_DEVICES=<uuids>` | **YES**, set by the plugin (`deviceListStrategy: envvar`). Inert here, because no nvidia-container-runtime reads it | 6.2 env; node has runc only |
| libnvidia-ml.so / nvidia-smi / libcuda.so injected | **NO**. No mounts, no CDI, no NVIDIA runtime hook | 6.2 mounts, hooks, find (with positive control) |
| CDI | **NO**. containerd has CDI on, and the node agent stages `/var/run/cdi/nvidia.yaml` and `/var/run/cdi/nvml-mock-nri.yaml`, but the plugin emits no CDI references in envvar mode | 6.2 "no CDI_devices"; `ls /var/run/cdi` |
| NRI ambient overlay | **NO**. The chart's `nri.enabled` defaults to false, and the guide leaves it off | step 4 install values |
| Runtime hook in the kind node image | **NO**. The only hook is kind's `/kind/bin/mount-product-files.sh` | 6.2 hooks |

**Conclusion.** Following the guide, an arbitrary image (vllm, sglang) gets only the
allocated `/dev/nvidiaN` nodes and `NVIDIA_VISIBLE_DEVICES`. It gets no
`libnvidia-ml.so`, no `nvidia-smi`, and no `libcuda.so`.

To give it the mock driver, add this to the pod spec (tested in 6.3):
- hostPath `/var/lib/nvml-mock` mounted read-only at `/opt/nvml-mock`
- `PATH` prefixed with `/opt/nvml-mock/driver/usr/bin`, which gives
  `nvidia-smi` at `/opt/nvml-mock/driver/usr/bin/nvidia-smi`
- `LD_LIBRARY_PATH=/opt/nvml-mock/driver/usr/lib64`, which gives
  `libnvidia-ml.so.1` and the mock `libcuda.so.1` from there
- `MOCK_NVML_CONFIG=/opt/nvml-mock/driver/config/config.yaml`

INFERENCE, not tested: the NRI overlay also appends the IB/PCI `LD_PRELOAD` shims
and `MOCK_PCI_ROOT`. The manual recipe leaves them out, so a workload reading
`/sys/bus/pci` sees the real (kind) sysfs, not the mock PCI tree.

INFERENCE, not tested: `LD_LIBRARY_PATH` puts the mock `libcuda.so.1` ahead of
anything else, so torch's `dlopen("libcuda.so.1")` resolves to the 15-function shim.
The same directory holds `libcudart.so.12 -> libcuda.so.1`. If an engine image
loads a CUDA 12 runtime by soname through the loader path, the shim shadows it.
A CUDA 13 build (`libcudart.so.13`) is not shadowed. Wave-1 should check which
`libcudart` its engine loads (`ldd` / `LD_DEBUG=libs`).

INFERENCE, not tested: the device plugin's `--device-list-strategy=cdi-cri` would
make containerd apply `/var/run/cdi/nvidia.yaml`. That spec bind-mounts
`libnvidia-ml.so.1` at `/usr/lib64/`, `nvidia-smi` at `/usr/bin/`, and the config
at `/etc/nvml-mock`. It also declares a `createContainer` hook at
`/usr/bin/nvidia-cdi-hook`, which is absent on this node (see step 2). Under
plain runc, container creation would probably fail on that hook. I did not try it.

## Step 7: node assignment (script `a-step7-assign.sh`, log `a-step7-assign.log`)

```
$ kubectl --context kind-mokka-vr200-llm label node mokka-vr200-llm-worker  spike.mokka/track=vllm
node/mokka-vr200-llm-worker labeled
$ kubectl --context kind-mokka-vr200-llm label node mokka-vr200-llm-worker2 spike.mokka/track=sglang
node/mokka-vr200-llm-worker2 labeled
$ kubectl --context kind-mokka-vr200-llm label node mokka-vr200-llm-worker3 spike.mokka/track=cpu
node/mokka-vr200-llm-worker3 labeled
$ kubectl --context kind-mokka-vr200-llm create namespace spike-vllm / spike-sglang / spike-cpu
namespace/spike-vllm created
namespace/spike-sglang created
namespace/spike-cpu created
$ kubectl --context kind-mokka-vr200-llm get nodes -L spike.mokka/track
NAME                            STATUS   ROLES           VERSION   TRACK
mokka-vr200-llm-control-plane   Ready    control-plane   v1.37.0
mokka-vr200-llm-worker          Ready    <none>          v1.37.0   vllm
mokka-vr200-llm-worker2         Ready    <none>          v1.37.0   sglang
mokka-vr200-llm-worker3         Ready    <none>          v1.37.0   cpu
```

| Node (docker container name) | Track label | Namespace | GPUs |
|---|---|---|---|
| mokka-vr200-llm-worker | `spike.mokka/track=vllm` | spike-vllm | 4 |
| mokka-vr200-llm-worker2 | `spike.mokka/track=sglang` | spike-sglang | 4 |
| mokka-vr200-llm-worker3 | `spike.mokka/track=cpu` | spike-cpu | 4 |

All three workers also carry `mokka.nvidia.com/type=sgpu`. To pin a pod to a node, use
`nodeSelector: {spike.mokka/track: <track>}`.

## Step 8: pre-pulls

### Attempt 1: aborted on purpose

I launched attempt 1 at 05:40:17Z, alongside the image build, to save wall time.
Aggregate pull throughput was about 9 MB/s. The node content stores grew from
668/642/755 MB to 999/889/1053 MB between 05:42:03Z and 05:43:36Z. Meanwhile
the build's `apt-get update` needed 180 s for 8.7 MB:

```
#34 2.251 Get:4 http://deb.debian.org/debian bookworm/main arm64 Packages [8689 kB]
#34 181.8 Get:5 http://deb.debian.org/debian bookworm-updates/main arm64 Packages [6936 B]
```

I stopped the pulls with `a-stop-pulls.sh`: killed the host loops first so none went
on to its next image, then ran `pkill -f 'crictl pull'` in each node. The build
finished 50 s later. Attempt-1 logs were kept as `a-pull-*.attempt1.log`:

```
time="2026-09-23T05:43:51Z" level=fatal msg="pulling image: interrupted: context canceled"
```

### Attempt 2 (live), launched 2026-09-23T05:48:56Z after verification

Script `a-step8-pull.sh <node> <image>...` runs `docker exec <node> crictl pull`
for each image in order and logs `START` / `END ... PULL_RC=<rc>` / `ALL_DONE`.

```
$ nohup a-step8-pull.sh mokka-vr200-llm-worker  docker.io/vllm/vllm-openai:v0.30.0 > a-pull-vllm-worker.log 2>&1 &
vllm pid=54154
$ nohup a-step8-pull.sh mokka-vr200-llm-worker2 docker.io/lmsysorg/sglang:v0.5.20 > a-pull-sglang-worker2.log 2>&1 &
sglang pid=54155
$ nohup a-step8-pull.sh mokka-vr200-llm-worker3 docker.io/vllm/vllm-openai-cpu:v0.30.0 docker.io/lmsysorg/sglang:v0.5.20-xeon > a-pull-cpu-worker3.log 2>&1 &
cpu pid=54156
```

Log paths:
- `/tmp/vr200-llm-spike-58fc971e/a-pull-vllm-worker.log`
- `/tmp/vr200-llm-spike-58fc971e/a-pull-sglang-worker2.log`
- `/tmp/vr200-llm-spike-58fc971e/a-pull-cpu-worker3.log`. The xeon pull starts only
  after vllm-openai-cpu finishes, and its verbatim result, success or an arm64
  platform error, will be the `PULL_RC` line in this log.

First progress check (05:49:06Z):

```
--- a-pull-vllm-worker.log
=== 2026-09-23T05:48:56Z START node=mokka-vr200-llm-worker image=docker.io/vllm/vllm-openai:v0.30.0
--- a-pull-sglang-worker2.log
=== 2026-09-23T05:48:56Z START node=mokka-vr200-llm-worker2 image=docker.io/lmsysorg/sglang:v0.5.20
--- a-pull-cpu-worker3.log
=== 2026-09-23T05:48:56Z START node=mokka-vr200-llm-worker3 image=docker.io/vllm/vllm-openai-cpu:v0.30.0
mokka-vr200-llm-worker:  containerd store 1114MB; no vllm/sglang image complete yet
mokka-vr200-llm-worker2: containerd store 1100MB; no vllm/sglang image complete yet
mokka-vr200-llm-worker3: containerd store 1122MB; no vllm/sglang image complete yet
```

To check progress:
`tail -2 /tmp/vr200-llm-spike-58fc971e/a-pull-*.log` (look for `PULL_RC=0` and `ALL_DONE`),
`docker exec <node> crictl images | grep -E 'vllm|sglang'`, or
`docker exec <node> du -sm /var/lib/containerd` for a rough byte count.
At about 9 MB/s aggregate, about 25 GB takes roughly 45 min or more (INFERENCE,
extrapolated from the attempt-1 rate). The three pulls share one link, so
running any other large download at the same time slows everything.

## Resource snapshot (concern 2)

```
$ docker exec mokka-vr200-llm-worker free -m          # Docker Desktop VM, shared by all kind clusters
               total        used        free      shared  buff/cache   available
Mem:           16222       11498         144         938        5769        4724
Swap:           1023        1023           0
$ docker exec mokka-vr200-llm-worker nproc
14
$ docker stats --no-stream (selected)
mokka-vr200-llm-control-plane  1.075GiB   mokka-vr200-llm-worker  337.5MiB
mokka-vr200-llm-worker2        307.3MiB   mokka-vr200-llm-worker3 358.4MiB
aicr-rc2-slinky-control-plane  2.942GiB   bench-mokka-* (5 nodes) about 4.6GiB total
mokka-ns-v120-* about 1.4GiB   k8slab-v132-control-plane 643.4MiB
```

Of the six clusters CONTEXT.md lists, `kind get clusters` now shows only four
others (aicr-rc2-slinky, bench-mokka, k8slab-v132, mokka-ns-v120). aicr-fb2 and
aicr-rc2 were already gone when I started. I did not touch any of them.

## Files

- Kind config: `/tmp/vr200-llm-spike-58fc971e/a-kind-config.yaml`
- Device-plugin manifest (identical to the guide): `/tmp/vr200-llm-spike-58fc971e/a-device-plugin.yaml`
- Manual-injection pod (the recipe for wave 1): `/tmp/vr200-llm-spike-58fc971e/a-gpu-pod-manual.yaml`
- Step scripts and logs: `/tmp/vr200-llm-spike-58fc971e/a-step{1..8}-*.{sh,log}`, `a-step6{a,b,c}-*`
- OCI spec of the guide pod: `/tmp/vr200-llm-spike-58fc971e/a-gpu-pod-busybox.crictl-inspect.json`

No tracked repo files were edited. Nothing was committed or pushed.
