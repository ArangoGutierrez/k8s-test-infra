# Task H4 report: vLLM detection per GPU type through DRA, plus the real-L4 safety check

Status: DONE_WITH_CONCERNS (2026-09-23 11:55Z to 13:00Z). All five brief steps
done for h100, gb300 and vr200. Identity matches the ResourceSlices on every
field; no process ever appeared on the L4. The concerns are findings F1 to F3:
the pods can open the host's real NVIDIA devices (F1), and DRA's injection
alone makes the mock report an A100 (F2).

Scope kept: namespace `detect-vllm` only; nodes mokka-hetero-worker (h100),
-worker4 (gb300), -worker7 (vr200); one Job at a time (every run log shows
`pre jobs in detect-vllm: 0`); 3Gi memory limit. Nothing pushed or posted.

Artefacts:
- VM: `~/mokka-hetero/h4/{probes,manifests,scripts,out,logs}`
- local copies: `/tmp/mokka-hetero-58fc971e/h4/`, with the same layout. Each run
  directory `out/<type>/` holds pod.log, claims.yaml, node-cdi.txt (the claim's
  CDI spec), pod.yaml, events.txt, watchdog.log and dmesg-nvrm.txt. `out/live-slices.json`
  holds the three nodes' ResourceSlices, taken after the runs.

## What ran

| File | Role |
|---|---|
| manifests/base.yaml | Namespace plus ResourceClaimTemplates h100-x1, gb300-x1, vr200-x1: the H2 documents with only the namespace changed. Proof: `diff <(awk ... h2/dra/claim-templates.yaml \| sed s/mokka-hetero-sched/NS/) <(awk ... h4/manifests/base.yaml \| sed s/detect-vllm/NS/)` gives `diff_rc=0` |
| manifests/job.tmpl.yaml | Job per type: `resourceClaimTemplateName: <type>-x1`, `nodeSelector kubernetes.io/hostname`, `imagePullPolicy: Never`, limit 3Gi, backoffLimit 0. The init container and volumes are the spike's `vllm-discovery.yaml` (Mokka NVML copied into an emptyDir, driver root mounted at /opt/nvml-mock). The container env sets no PATH, LD_LIBRARY_PATH or MOCK_NVML_CONFIG, so phase A sees DRA's injection alone |
| probes/h4_detect.sh | Phase A: record what DRA and CDI injected (brief step 2). Phase B: the spike's exposure, exported by the script (step 3), then the CUDA error and `vllm serve` (step 4) |
| probes/vllm_discovery.py | The spike probe, with one line changed: `is_fully_connected([0,1,2,3])` became "every visible device". One claimed GPU leaves 1 device, and index 1 would fail |
| probes/cuda_init.py | Raw `cuInit`/`cuDeviceGetCount` through ctypes, then torch. If cuInit returns 0 (a real kernel module accepted this libcuda), it stops before torch and `vllm serve` is skipped |
| probes/nvml_identity.py | Which libnvidia-ml is loaded, and what identity it reports |
| scripts/h4-l4-watchdog.sh | Polls `nvidia-smi --query-compute-apps` on the VM host every second for the whole Job. Any process: it deletes the Job and pod and writes `<job>.L4-ALERT` |
| scripts/h4-run.sh | Pre-checks: no leaked host /dev/nvidia* on the node, no other Job, L4 idle, NVRM dmesg baseline. Then it starts the watchdog, applies the Job, captures the claim and the node's claim CDI spec while the pod runs, collects logs and runs the after-checks, deletes the Job and checks that the claim and CDI spec are gone |
| scripts/h4-check.py | Gate: phase B identity equals the allocated device's slice entry and the brief's fixed values, and there is no sign of L4 activity. Exits 1 on any mismatch |

Watchdog discrimination, checked before the first Job (`scripts/h4-watchdog-selftest.sh`,
using nvidia-smi PATH shims, so no GPU was touched):
```
== busy: alert file PRESENT
2026-09-23T12:37:31Z poll=1 L4 PROCESS: 4242, /fake/proc, 123 MiB
== idle: alert file absent
stop 2026-09-23T12:37:40Z polls=4 nvsmi_fails=0 alert=no
selftest_rc=0
```

Runs (all `result=succeeded`): vr200 run1 12:38:31-12:40:15Z, h100 12:44:32-12:46:15Z,
gb300 12:46:48-12:48:26Z, vr200 run2 12:48:47-12:50:18Z. After run1 I added
phase-A checks A9-A11 and re-ran vr200, so all three types ran the same probe.
Phase-B RESULT lines of vr200 run1 and run2 are identical:
`diff r1.txt r2.txt` rc=0 over 21 lines.

## Step 1: allocation (from each run log and claims.yaml)

```
h4-vllm-h100-nd9rb-gpu-vx9x4  pool=mokka-hetero-worker  device=gpu-3 driver=gpu.nvidia.com reservedFor=h4-vllm-h100-nd9rb
h4-vllm-gb300-tt2qz-gpu-gqmdf pool=mokka-hetero-worker4 device=gpu-3 driver=gpu.nvidia.com reservedFor=h4-vllm-gb300-tt2qz
h4-vllm-vr200-qkv9r-gpu-lr9w2 pool=mokka-hetero-worker7 device=gpu-0 driver=gpu.nvidia.com reservedFor=h4-vllm-vr200-qkv9r   (run2; run1 also gpu-0)
```
Each pod ran on its pinned node (`pod ... node=mokka-hetero-worker7`, and so on).
After each Job: `claims left in detect-vllm: 0`, `claim CDI specs left on <node>: 0`.

The DRA driver's claim CDI spec (vr200, `out/vr200-run1/node-cdi.txt`, trimmed):
```
kind: k8s.gpu.nvidia.com/claim
devices:
    - name: 290c3eea-...-gpu-0
      containerEdits:
        deviceNodes:
            - path: /dev/nvidia0
              hostPath: /var/lib/nvml-mock/driver/dev/nvidia0
              major: 195
containerEdits:
    env:
        - NVIDIA_CTK_LIBCUDA_DIR=/usr/lib64
        - NVIDIA_VISIBLE_DEVICES=void
    deviceNodes: /dev/nvidia-uvm 510:0, /dev/nvidia-uvm-tools 510:1, /dev/nvidiactl 195:255
    hooks (nvidia-cdi-hook): create-symlinks
                               --link libcuda.so.1::/usr/lib64/libcuda.so
                               --link libcuda.so.615.23::/usr/lib64/libcuda.so
                               --link libnvidia-ml.so.615.23::/usr/lib64/libnvidia-ml.so.1
                               --link libnvidia-ml.so.1::/usr/lib64/libnvidia-ml.so
                             enable-cuda-compat --host-driver-version=615.23
                             update-ldcache --folder /usr/lib64
                             disable-device-node-modification
                             update-application-profile
    mounts: /usr/bin/nvidia-smi, /usr/lib64/libcuda.so.615.23, /usr/lib64/libnvidia-ml.so.615.23 (from /var/lib/nvml-mock/driver)
```
No `MOCK_NVML_CONFIG` env and no `/etc/nvml-mock` mount. The only
difference in the h100 and gb300 specs is the version in file names and in
`--host-driver-version` (`550.163.01`, `570.124.06`), plus `/dev/nvidia3 195:3`.

## Step 2: what DRA/CDI put into the pod (phase A, no probe exposure)

Same on all three types except where noted (`out/<type>/pod.log`, section A):

```
== A1 /dev/nvidia*                                   (vr200)
crw-rw-rw- 1 root root 510,   0 /dev/nvidia-uvm
crw-rw-rw- 1 root root 510,   1 /dev/nvidia-uvm-tools
crw-rw-rw- 1 root root 195,   0 /dev/nvidia0
crw-rw-rw- 1 root root 195, 255 /dev/nvidiactl
                                                     (h100, gb300: 195, 3 /dev/nvidia3 instead of nvidia0)
== A2 env
LD_LIBRARY_PATH=/usr/local/nvidia/lib64:/usr/local/cuda/lib64:/usr/local/cuda/lib64:/usr/local/nvidia/lib:/usr/local/nvidia/lib64:/usr/local/cuda/lib64
NVIDIA_CTK_LIBCUDA_DIR=/usr/lib64
NVIDIA_VISIBLE_DEVICES=void
VLLM_ENABLE_CUDA_COMPATIBILITY=0          (image env; no MOCK_* variable present)
== A3 ldconfig -p                                    (vr200)
	libnvidia-ml.so.1 (libc6,x86-64) => /usr/lib64/libnvidia-ml.so.1
	libnvidia-ml.so (libc6,x86-64) => /usr/lib64/libnvidia-ml.so
	libcuda.so.615.23 (libc6,x86-64) => /usr/lib64/libcuda.so.615.23
	libcuda.so (libc6,x86-64) => /usr/lib64/libcuda.so
== A3 ldconfig -p                                    (h100; gb300 identical with 570.124.06)
	libcuda.so.550.163.01 (libc6,x86-64) => /usr/lib64/libcuda.so.550.163.01
	libcuda.so.1 (libc6,x86-64) => /usr/local/cuda-13.0/compat/libcuda.so.1
	libcuda.so (libc6,x86-64) => /usr/local/cuda-13.0/compat/libcuda.so
	libcuda.so (libc6,x86-64) => /usr/lib64/libcuda.so
== A4 find / -name 'libnvidia-ml.so*' -o -name 'libcuda.so*'  (prunes /proc, /sys and our two /opt mounts; vr200)
/usr/lib64/libcuda.so
/usr/lib64/libcuda.so.615.23
/usr/lib64/libnvidia-ml.so
/usr/lib64/libnvidia-ml.so.1
/usr/lib64/libnvidia-ml.so.615.23
/usr/local/cuda-13.0/compat/libcuda.so
/usr/local/cuda-13.0/compat/libcuda.so.1
/usr/local/cuda-13.0/compat/libcuda.so.580.95.05
/usr/local/cuda-13.0/targets/x86_64-linux/lib/stubs/libcuda.so
== A6 nvidia-smi                                     (vr200)
nvidia-smi at /usr/bin/nvidia-smi
GPU 0: Mock NVIDIA A100-SXM4-40GB (UUID: GPU-4d4f434b-0000-0000-0000-000000000000)
Mock NVIDIA A100-SXM4-40GB, 40960 MiB, 8.0, 550.163.01, 00000000:01:00.0
== A7 NVML identity through default library resolution   (vr200)
IDENTITY MOCK_NVML_CONFIG=None
IDENTITY nvml_lib=['/usr/lib64/libnvidia-ml.so.615.23']
IDENTITY driver=550.163.01 count=1
IDENTITY gpu0 name=Mock NVIDIA A100-SXM4-40GB arch=7 cc=8.0 mem=42949672960 minor=0 uuid=GPU-4d4f434b-...-000000000000 pci=00000000:01:00.0
== A8 MOCK_NVML_DEBUG=1
[CONFIG] Using env/default config: 8 devices, driver 550.163.01
[ENGINE] Creating devices with default config
[ENGINE] Device visibility filtering: 1 of 8 GPUs visible (by /dev/nvidia* presence)
== A9 /proc (read only)
NVRM version: NVIDIA UNIX Open Kernel Module for x86_64  595.71.05  Release Build  (dvs-builder@U22-I3-G08-03-1)  Fri Apr 24 06:42:30 UTC 2026
0000:31:00.0
== A10 open()+close() of each injected /dev/nvidia*  (no ioctl, no CUDA)
vr200:       OPEN /dev/nvidia-uvm ok / OPEN /dev/nvidia-uvm-tools ok / OPEN /dev/nvidia0 ok / OPEN /dev/nvidiactl ok
h100, gb300: OPEN /dev/nvidia-uvm ok / OPEN /dev/nvidia-uvm-tools ok / OPEN /dev/nvidia3 errno=19 ENODEV (No such device) / OPEN /dev/nvidiactl ok
== A11 dlopen("libcuda.so.1") only, no cuInit
vr200:       DLOPEN libcuda.so.1 failed: libcuda.so.1: cannot open shared object file: No such file or directory
h100, gb300: DLOPEN libcuda.so.1 ok: ['/usr/local/cuda-13.0/compat/libcuda.so.580.95.05']
```

Answers to step 2:
- **MOCK_NVML_CONFIG did not reach the pod** on any type (`IDENTITY MOCK_NVML_CONFIG=None`).
  DRA's claim spec carries neither the env nor the config mount.
- **With DRA's injection alone, NVML reports the default A100** on all three types:
  "Mock NVIDIA A100-SXM4-40GB", CC 8.0, 40 GiB, driver 550.163.01. So does the
  injected nvidia-smi. The warning in the brief (task B, #747) holds for DRA too.
  See F2.
- Host side, for the majors (VM host):
  ```
  $ nvidia-smi --query-gpu=name,pci.bus_id,driver_version,persistence_mode --format=csv,noheader
  NVIDIA L4, 00000000:31:00.0, 595.71.05, Enabled
  $ ls -l /dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm ; grep -E "^(195|510) " /proc/devices
  crw-rw-rw- 1 root root 195,   0 Sep  9 11:08 /dev/nvidia0
  crw-rw-rw- 1 root root 195, 255 Sep  9 11:08 /dev/nvidiactl
  crw-rw-rw- 1 root root 510,   0 Sep  9 11:08 /dev/nvidia-uvm
  195 nvidia / 195 nvidiactl / 510 nvidia-uvm
  ```
  The vr200 pod's `/dev/nvidia0` is 195:0, which is the L4. The pod's /proc lists
  the L4's PCI address, 0000:31:00.0. See F1.

## Step 3: discovery with the proven exposure (phase B)

Exposure: `LD_LIBRARY_PATH=/opt/nvml-only:/usr/local/cuda-13.0/compat:...`,
`MOCK_NVML_CONFIG=/opt/nvml-mock/driver/config/config.yaml`, PATH with
/opt/nvml-mock/driver/usr/bin first. The loaded NVML is confirmed per run, for example
`IDENTITY nvml_lib=['/opt/nvml-only/libnvidia-ml.so.615.23']`.

```
h100:  GPU 0: NVIDIA H100 80GB HBM3 (UUID: GPU-01000100-0000-0000-0000-000000000003)
       IDENTITY gpu0 name=NVIDIA H100 80GB HBM3 arch=9 cc=9.0 mem=85899345920 minor=3 uuid=GPU-01000100-...-000000000003 pci=00000000:4B:00.0
       RESULT vllm_version=0.30.0          RESULT platform=NvmlCudaPlatform
       RESULT device_name_0=NVIDIA H100 80GB HBM3
       RESULT compute_capability_0=9.0     RESULT total_memory_bytes_0=85899345920
       RESULT nvml_visible_device_count=1  RESULT nvlink_fully_connected_visible=True
       RESULT fp8_supported=True           RESULT nvfp4_cutlass_supported=False
       RESULT deep_gemm_supported=True     RESULT trtllm_attention_supported=False
       RESULT cuda_context_created=False
gb300: GPU 0: NVIDIA GB300 NVL (UUID: GPU-b300b300-0000-0000-0000-000000000003)
       IDENTITY gpu0 name=NVIDIA GB300 NVL arch=10 cc=10.0 mem=309237645312 minor=3 uuid=GPU-b300b300-...-000000000003 pci=00000000:4B:00.0
       RESULT platform=NvmlCudaPlatform    RESULT device_name_0=NVIDIA GB300 NVL
       RESULT compute_capability_0=10.0    RESULT total_memory_bytes_0=309237645312
       RESULT nvml_visible_device_count=1  RESULT nvlink_fully_connected_visible=True
       RESULT fp8_supported=True           RESULT nvfp4_cutlass_supported=True
       RESULT deep_gemm_supported=True     RESULT trtllm_attention_supported=True
       RESULT cuda_context_created=False
vr200: GPU 0: NVIDIA Graphics Device (UUID: GPU-307f0000-0000-0000-0000-000000000000)
       IDENTITY gpu0 name=NVIDIA Graphics Device arch=13 cc=10.7 mem=309237645312 minor=0 uuid=GPU-307f0000-...-000000000000 pci=00000002:81:00.0
       RESULT platform=NvmlCudaPlatform    RESULT device_name_0=NVIDIA Graphics Device
       RESULT compute_capability_0=10.7    RESULT total_memory_bytes_0=309237645312
       RESULT nvml_visible_device_count=1  RESULT nvlink_fully_connected_visible=True
       RESULT fp8_supported=True           RESULT nvfp4_cutlass_supported=True
       RESULT deep_gemm_supported=True     RESULT trtllm_attention_supported=True
       RESULT cuda_context_created=False
```
NVML architecture enums, from go-nvml v0.13.3-1 const.go:114-122:
`DEVICE_ARCH_AMPERE = 7`, `HOPPER = 9`, `BLACKWELL = 10`, `RUBIN = 13`.

## Step 4: CUDA error text and real-L4 safety

Identical on all three types (`out/<type>/pod.log`, B4/B5):
```
RESULT libcuda_loaded=['/usr/local/cuda-13.0/compat/libcuda.so.580.95.05']
RESULT libcuda_driver_version=13000
RESULT cuinit_rc=803 CUDA_ERROR_SYSTEM_DRIVER_MISMATCH (system has unsupported display driver / cuda driver combination)
RESULT cudevicegetcount_rc=3 CUDA_ERROR_NOT_INITIALIZED (initialization error) count=-1
RESULT torch_cuda_available=False torch_device_count=1
RESULT torch_warning=CUDA initialization: Unexpected error from cudaGetDeviceCount(). ... Error 803: system has unsupported display driver / cuda driver combination (Triggered internally at /__w/pytorch/pytorch/c10/cuda/CUDAFunctions.cpp:119.)
RESULT torch_cuda_init_error=RuntimeError: Unexpected error from cudaGetDeviceCount(). ... Error 803: system has unsupported display driver / cuda driver combination
RESULT torch_cuda_initialized=False
RESULT hf_reachable=200
RESULT serve_rc=1
RESULT serve_stop=RuntimeError: Unexpected error from cudaGetDeviceCount(). Did you run some cuda functions before calling NumCudaDevices() that might have already set an error? Error 803: system has unsupported display driver / cuda driver combination
RESULT serve_listening=0
(EngineCore) ERROR [core.py:1366]     self.driver_worker.init_device()   ...   torch._C._cuda_init()
(APIServer)  RuntimeError: Engine core initialization failed. See root cause above. Failed core proc(s): {}
```
`serve_config` differs: `max_num_batched_tokens=8192` on h100 and 16384 on
gb300 and vr200.

This is a driver/library mismatch (error 803), not the Mac spike's "No CUDA GPUs
are available". The difference is that this VM has a real NVIDIA kernel module
(595.71.05), and the image's compat libcuda (580.95.05) is older than it.

L4 host checks, per run (run logs; the watchdog polled every second for the whole Job):

| run | compute apps before | watchdog | compute apps after | L4 after | new NVRM dmesg lines |
|---|---|---|---|---|---|
| vr200 run1 | `[]` | `polls=92 nvsmi_fails=0 alert=no` | `[]` | `NVIDIA L4, 20 MiB, 0 %` | 0 |
| h100 | `[]` | `polls=92 nvsmi_fails=0 alert=no` | `[]` | `NVIDIA L4, 20 MiB, 0 %` | 0 |
| gb300 | `[]` | `polls=87 nvsmi_fails=0 alert=no` | `[]` | `NVIDIA L4, 20 MiB, 0 %` | 0 |
| vr200 run2 | `[]` | `polls=80 nvsmi_fails=0 alert=no` | `[]` | `NVIDIA L4, 20 MiB, 0 %` | 0 |

Final state at 12:59:28Z: `nvidia-smi --query-compute-apps` prints only its header,
`NVIDIA L4, 20 MiB, 0 %`, and no h4 process is running (`pgrep -af h4-` matched only
itself). Worker, worker4 and worker7 keep `StartedAt=2026-09-23T10:10:57Z` and
`leaked=0`, so no node restarted and s3b was not needed.
The NVRM dmesg count stayed 0. I did not establish that this driver logs a
UMD/KMD mismatch at all, so that column is weak evidence. The watchdog and
compute-apps columns are the criterion the brief sets.

## Step 5: table

Identity fields are checked by the gate below. Feature flags are recorded, not asserted.

| | h100 (worker, gpu-3) | gb300 (worker4, gpu-3) | vr200 (worker7, gpu-0) |
|---|---|---|---|
| platform | NvmlCudaPlatform | NvmlCudaPlatform | NvmlCudaPlatform |
| device name | NVIDIA H100 80GB HBM3 | NVIDIA GB300 NVL | NVIDIA Graphics Device |
| NVML architecture | 9 (Hopper) | 10 (Blackwell) | 13 (Rubin) |
| compute capability | 9.0 | 10.0 | 10.7 |
| total memory | 85899345920 (80Gi) | 309237645312 (288Gi) | 309237645312 (288Gi) |
| fully connected | True (vacuous: 1 visible device) | True (vacuous) | True (vacuous) |
| fp8 | True | True | True |
| nvfp4 (CUTLASS) | False | True | True |
| DeepGEMM | True | True | True |
| TRT-LLM attention | False | True | True |
| CUDA context created | False | False | False |
| cuInit | 803 SYSTEM_DRIVER_MISMATCH | 803 | 803 |
| `vllm serve` stop | RuntimeError ... Error 803 (EngineCore init_device) | same | same |
| identity with DRA injection alone | Mock NVIDIA A100-SXM4-40GB, 8.0, 40 GiB | same | same |
| libcuda.so.1 with DRA injection alone | image compat 580.95.05 | image compat 580.95.05 | does not resolve |

Gate (`python3 scripts/h4-check.py out/gate out/live-slices.json`, where `out/gate/{h100,gb300,vr200}`
link to `h100`, `gb300` and `vr200-run2`). 17 checks per type. Excerpt, rc=0:
```
== vr200
   allocated mokka-hetero-worker7/gpu-0 on gpu.nvidia.com
PASS vllm device_name_0 == fixed              got='NVIDIA Graphics Device' want='NVIDIA Graphics Device'
PASS vllm compute_capability_0 == fixed       got='10.7' want='10.7'
PASS vllm total_memory_bytes_0 == fixed       got=309237645312 want=309237645312
PASS nvml arch enum == fixed                  got=13 want=13
PASS slice productName == nvidia-smi -L       got='NVIDIA Graphics Device' want='NVIDIA Graphics Device'
PASS slice cc == vllm cc                      got='10.7' want='10.7'
PASS slice memory == vllm bytes               got=309237645312 want=309237645312
PASS slice uuid == nvml uuid                  got='GPU-307f0000-0000-0000-0000-000000000000' want='GPU-307f0000-0000-0000-0000-000000000000'
PASS slice pciBusID == nvml busId             got='0002:81:00.0' want='0002:81:00.0'
PASS watchdog saw no L4 process               got=False want=False
...
CHECK fails=0
check rc=0
```
(h100: 9.0 / 85899345920 / enum 9 / gpu-3 uuid ...003 / 0000:4b:00.0. gb300: 10.0 / 309237645312 /
enum 10 / uuid GPU-b300b300-...-003 / 0000:4b:00.0. All PASS.)
The slices come from `live-slices.json`, taken after the runs. For all three types
their device lists equal H1's dumps: `diff <(jq -S .<t>.items[0].spec.devices live) <(jq -S .items[0].spec.devices h1/resourceslice-<t>.json)`
gives rc=0 for h100, gb300 and vr200.

Mutation check for the gate (`scripts/h4-check-mutate.sh`). Each mutant changes one
input line (its diff is printed), and each one turns the gate red:
```
== baseline: rc=0 0 FAIL line(s)
== M1 vr200 vLLM reports CC 10.0: rc=1 2 FAIL line(s)        (compute_capability_0 == fixed; slice cc == vllm cc)
== M2 vr200 NVML (phase B) reports Blackwell enum 10: rc=1 1 FAIL line(s)
== M3 claim names a different device than the pod saw: rc=1 2 FAIL line(s)   (uuid, pciBusID)
== M4 watchdog saw an L4 process: rc=1 1 FAIL line(s)
== M5 NVRM kernel line appeared: rc=1 1 FAIL line(s)
```

## Findings

- **F1 (safety): a pod holding a mock GPU can open the host's real NVIDIA
  devices. Only the UMD/KMD version mismatch kept CUDA off the L4.**
  - The mock stages its device nodes with the real driver's majors
    (`/var/lib/nvml-mock/driver/dev/nvidia0..N` 195:N, nvidiactl 195:255, nvidia-uvm 510:0;
    `ls -la` on worker, worker4 and worker7). DRA's CDI spec injects them.
  - On this host, 195:0 is the L4 and 195:255 and 510:0 are its control and UVM devices.
  - Measured in the pods:
    - `OPEN /dev/nvidiactl ok` and `OPEN /dev/nvidia-uvm ok` on all three types;
    - `OPEN /dev/nvidia0 ok` on vr200, where DRA allocated gpu-0 (minor 0);
    - `/dev/nvidia3 ENODEV`, because the host has no minor 3;
    - /proc shows the host module, 595.71.05, and the L4's PCI address.
  - cuInit then failed with 803, because the image's compat libcuda is 580.95.05.
  - INFERENCE (not tested, and must not be): an image whose libcuda matches
    595.71.05, or a forward-compat libcuda newer than it (the L4 is a datacenter
    part), would create a CUDA context on the physical L4 from a pod that DRA says
    holds a VR200.
  - Any gpu-0 claim on any real node can reach the L4's minor. So can nvidiactl
    and uvm on every claim.
  - H1's s3b fix removes the host's leaked nodes from each kind node's /dev. It
    does not cover the mock's own staged nodes, which reuse the same numbers.
  - Mitigations, none tested:
    - run the real tier on a host with no NVIDIA kernel module;
    - have Mokka stage the device nodes with a major the host does not use;
    - never run an image whose libcuda is >= 595.71.05 on this cluster.
- **F2: with DRA's injection alone, the mock NVML reports the default A100, not the
  profile.**
  - DRA's claim CDI spec (above) mounts `libnvidia-ml.so.<ver>` at `/usr/lib64` and
    sets no `MOCK_NVML_CONFIG`.
  - The engine's fallback chain (pkg/gpu/mocknvml/engine/config.go:71-74 and
    176-221) derives `<lib dir>/../../config/config.yaml`, which is `/config/config.yaml`
    here and does not exist. It then uses DefaultConfig (config.go:57-62:
    8 devices, 550.163.01).
  - Measured: `[CONFIG] Using env/default config: 8 devices, driver 550.163.01`, and
    identity "Mock NVIDIA A100-SXM4-40GB" on h100, gb300 and vr200.
  - So any workload that reads NVML in a DRA pod sees A100 CC 8.0, while the
    ResourceSlice that scheduled it says H100, GB300 or VR200.
  - Related to #747, but a different path: #747 is the toolkit dropping env for
    `nvidia.com/gpu`, while here the DRA driver's own spec never carries the env or
    the `/etc/nvml-mock` mount.
  - D2's identity numbers therefore rely on the explicit exposure (phase B), as the
    spike did.
- **F3: the mock libcuda has no SONAME, so DRA leaves no `libcuda.so.1`. The
  default libcuda then differs by mock driver version.**
  - `readelf -d libcuda.so.615.23` (copied from worker7) shows only
    `(NEEDED) Shared library: [libc.so.6]`. The same command on the mock
    libnvidia-ml prints `(SONAME) Library soname: [libnvidia-ml.so.1]`.
  - update-ldcache therefore registers `libcuda.so.615.23` under its file name, and
    create-symlinks makes `/usr/lib64/libcuda.so -> libcuda.so.<ver>`.
    No `/usr/lib64/libcuda.so.1` exists: A4's find, which does list the
    libnvidia-ml.so.1 symlink, has none.
  - Then the `enable-cuda-compat --host-driver-version=<mock driver>` hook decides:
    - h100 (550.163.01) and gb300 (570.124.06): ldconfig maps `libcuda.so.1` to the
      image's compat 580.95.05, and `dlopen` succeeds. A default DRA pod on a mock
      H100 or GB300 node loads a real NVIDIA user-mode driver. This is the F1 path.
    - vr200 (615.23): the compat libcuda is older, `libcuda.so.1` is absent, and
      dlopen fails.
  - INFERENCE: the hook enables compat only when compat is newer than
    `--host-driver-version`. The mechanism was not read in source; the effect is
    measured.
  - INFERENCE: on vr200 with DRA's injection alone, `import vllm` would fail,
    because its `_C` links `libcuda.so.1` (spike README). Not run.
- **F4:** `nvlink_fully_connected` is vacuous with a 1-GPU claim, since there are no
  pairs. A meaningful value needs a claim of every device on a node. I did not run
  one, to stay within the brief's count of 1.
- **F5:** GB300's compute capability is 10.0 end to end: slice, NVML and vLLM. That
  is the stack's belief, as SPEC notes; a real GB300 may report 10.3.
  vLLM enables the same feature set for 10.0 and 10.7. H100 differs only in
  nvfp4 and TRT-LLM attention (False).
- **F6:** `torch_device_count=1` while `torch_cuda_available=False`. INFERENCE: torch
  counts through NVML (the mock), which is why the count stays 1 after cuInit fails.

## Deviations from the brief (all additive)

1. I added phase-A checks A9 to A11 after vr200 run1, then re-ran vr200 so all types
   used one probe. **A10 opens and closes the injected device nodes: this touched the
   real kernel module (nvidiactl, uvm, and on vr200 the L4's /dev/nvidia0).** It made
   no ioctl and created no context, and no compute process appeared (watchdog table).
   I did it to turn H1's concern 2 ("INFERENCE, not tested") into a measurement.
   cuInit and `vllm serve`, which the brief asked for, reach the same driver anyway.
2. cuda_init.py adds raw cuInit and cuDeviceGetCount with a safety stop: if cuInit
   returns 0, torch and `vllm serve` are skipped. It never triggered: rc was 803 every time.
3. The watchdog deletes the Job by itself if a process appears. It was self-tested
   with PATH shims. It never fired.
4. vllm_discovery.py checks "fully connected" over the visible devices instead of
   [0,1,2,3] (F4).

## Left in the cluster

Namespace `detect-vllm` with ResourceClaimTemplates h100-x1, gb300-x1 and vr200-x1, and
ConfigMap h4-probes. There are no Jobs, pods or ResourceClaims (listing at 12:59:28Z shows only
those objects). Delete with `kubectl --context kind-mokka-hetero delete ns detect-vllm`
when no longer needed.

## Status

DONE_WITH_CONCERNS. Detection per type through DRA matches the ResourceSlices on
name, architecture, compute capability, memory, UUID and PCI bus ID, and the gate
is mutation-checked. VR200 is identified as Rubin 10.7, distinct from GB300's
Blackwell 10.0. The L4 stayed idle through all four Jobs. Concerns: F1 (real device
nodes reachable from mock-GPU pods, guarded only by a version mismatch), F2 (A100
identity with DRA's injection alone), F3 (no libcuda.so.1, type-dependent default
libcuda).
