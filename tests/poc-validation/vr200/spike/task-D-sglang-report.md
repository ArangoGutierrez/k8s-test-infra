# Task D report: SGLang v0.5.20 ladder on a Mokka vr200 node

Status: DONE_WITH_CONCERNS

- Image: `docker.io/lmsysorg/sglang:v0.5.20`, pulled digest (pod `imageID`)
  `docker.io/lmsysorg/sglang@sha256:06e4f2ed21afde4ff513cda65070124e727ba23ccaeff7712b8c40e1097d611f`
  (index digest; node image id `sha256:3ec36384d5eadedb920086d6e1b874e0bedf1d7bb773d2f56c3ccbacbb26d7bb`)
- Engine version printed by the engine: `sglang 0.5.20` (`python3 -c "import sglang; print(sglang.__version__)"`),
  `check_env`: `PyTorch: 2.13.0+cu130`, `sglang-kernel: 0.4.7`, `flashinfer_python: 0.6.18`, `triton: 3.7.1`
- Node: `mokka-vr200-llm-worker2` (`spike.mokka/track=sglang`), namespace `spike-sglang`, pod `sglang-ladder`
- Scratch files (scripts, logs, manifest): `/tmp/vr200-llm-spike-58fc971e/d-*`

| Rung | Result | Decisive evidence line |
|---|---|---|
| 1 Scheduled + GPUs visible | PASS | `NVIDIA Graphics Device, 294912 MiB, 10.7, 615.23` (x4) on `mokka-vr200-llm-worker2` |
| 2 SGLang's own discovery | PARTIAL | nvidia-smi/pynvml helpers read vr200 (`294912.0`, `(10, 7)`, `'615.23'`, fabric clique 32766, P2P OK), but `check_env` says `CUDA available: False` and every `is_cuda()`-gated path is off |
| 2b discovery with `PYTORCH_NVML_BASED_CUDA_CHECK=1` | PARTIAL (more) | `is_available True`, `get_device_memory_capacity = 294912.0`, `get_device_count = 4`, `CudaSRTPlatform`, `is_full_nvlink` (unmodified) True; but `get_device_sm/capability/name` and every `is_sm*`/`is_blackwell` raise "Found no NVIDIA driver"; `check_env` crashes |
| 3 torch CUDA init, FULL / NVML-ONLY | FAIL / FAIL | `avail False`, `count 4`, then `RuntimeError: Found no NVIDIA driver on your system...`. FULL: torch's `libcudart.so.13` asks Mokka's libcuda for `cuGetProcAddress_v2` first (NULL); 1 of 440 names resolves (`cuInit`). NVML-ONLY: `dlopen("libcuda.so.1")` NULL for cuBLASLt, cuSPARSELt and cudart |
| 4 launch_server | FAIL | `RuntimeError: No accelerator (CUDA, XPU, HPU, NPU, MUSA, MPS) or platform plugin is available.` at `pipeline.py:145`, t+15s, no download, never listening (FULL and NVML-ONLY identical) |
| 4b launch_server with `PYTORCH_NVML_BASED_CUDA_CHECK=1` | FAIL | `RuntimeError: Found no NVIDIA driver on your system...` at `pipeline.py:150` (DeepGEMM `configurer.py:18` `get_device_sm()`), t+15s; FULL and NVML-ONLY identical; no nvidia-smi, no download |
| 5 /v1/completions | NOT RUN | rung 4/4b never listened |

Concerns:

1. NUMA: Mokka's NVML answers memory affinity correctly, but SGLang's NUMA helper returns `[]` because this kind
   node's pods have no `/sys/devices/system/node`. That is an environment gap outside NVML. INFERENCE: it
   would hit any NUMA-aware engine on this cluster.
2. SGLang's NVLink check (`is_full_nvlink`) raises `NameError` unmodified in the default pod. It runs
   unmodified, and returns True, only with `PYTORCH_NVML_BASED_CUDA_CHECK=1` (rung 2b).
3. Unexplained variance: in 1 of 3 FULL runs of the phase-B probe (and 0 of 3 runs of `d-rung3-who.py`),
   `/proc/self/maps` did not show Mokka's libcuda after `is_available()`. The outcome was identical every
   time (rung 3.5).
4. Process note: an interim message I sent to main (~06:40Z) wrongly said `MOCK_NVML_DEBUG` does not log
   the device getters. I corrected it in a second message (~06:52Z). The facts are in "MOCK_NVML_DEBUG coverage".
5. The chief's follow-ups (2b, 4b, exact symbols) needed the pod again: I recreated it at ~08:05Z from the same
   manifest and deleted it again at the end. Two throwaway LD_PRELOAD tracers (`d-dltrace.c`,
   `d-dltrace-open.c`) were compiled inside the pod. They only observe; neither SGLang nor torch was patched.

The pod was deleted at the end (see "Cleanup"). Nothing else was touched outside `spike-sglang`.

## Source reading (SGLang v0.5.20, before the pod)

Source: task B's shallow clone (read-only, no second clone, to leave the link to the image pulls):
`S:` = `/tmp/vr200-llm-spike-58fc971e/taskB/sglang-v0.5.20`, HEAD `94602c9c2b7cbdb8efd5c52802dac6a1c180089e`.
The arm64 image config carries the same commit (`SGLANG_BUILD_COMMIT=94602c9c2b7cbdb8efd5c52802dac6a1c180089e`,
from `docker buildx imagetools inspect docker.io/lmsysorg/sglang:v0.5.20 --format '{{json .Image}}'`, saved as
`d-image-config.json`), so the clone matches the image's code. Rung 2 re-checks this inside the pod.

task-B-surface-report.md existed, but at 06:20Z its SGLang section still read "(pending)", so I picked the
discovery calls from the source below. Its SGLang table (4.3) appeared by ~06:50Z. It names the same helpers
(nvidia-smi memory/SM/driver, NUMA memory affinity, custom all-reduce P2P, fabric clique), and I used it for
"Prediction vs measurement".

Image facts (arm64 config): base `nvidia/cuda:13.0.3-cudnn-devel-ubuntu24.04` (`S:docker/Dockerfile:1-2`),
`CUDA_VERSION=13.0.3`, `torch==2.13.0` (`S:python/pyproject.toml:6`), Entrypoint `/opt/nvidia/nvidia_entrypoint.sh`
(the pod's `command:` replaces it, so it never runs), and:

```
PATH=/root/.cargo/bin:/opt/sglang/bin:/usr/local/nvidia/bin:/usr/local/cuda/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/nvidia/bin
LD_LIBRARY_PATH=/usr/local/nvidia/lib:/usr/local/nvidia/lib64:/usr/local/cuda/lib64:/usr/local/nvidia/lib:/usr/local/nvidia/lib64
```

### Which SGLang discovery helpers work without torch.cuda

| Helper (S:python/sglang/...) | How it reads the hardware | Needs torch.cuda? |
|---|---|---|
| `srt/utils/common.py:663` `get_nvgpu_memory_capacity()` | `nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits` (`:667`), returns min over GPUs in MiB; falls back to `torch.cuda.mem_get_info` only on nvidia-smi failure (`:630-660`) | No, when called directly. Its only caller `get_device_memory_capacity` (`:825`) gates it on `is_cuda()` (`:832`) |
| `srt/utils/common.py:1171` `get_device_sm_nvidia_smi()` | `nvidia-smi --query-gpu=compute_cap` | No |
| `srt/utils/common.py:1108` `get_nvidia_driver_version_str()` | `nvidia-smi --query-gpu=driver_version` | No |
| `srt/utils/numa_utils.py:388` `_query_numa_node_for_gpu(i)` | pynvml `nvmlDeviceGetHandleByIndex` + `nvmlDeviceGetMemoryAffinity(..., NVML_AFFINITY_SCOPE_NODE)` (`:413-422`), index via `torch.cuda._get_nvml_device_index` (env parsing only, `T:torch_cuda___init__.py:1128-1140`) | No. Its caller `_is_numa_available()` requires `_is_cuda` (`:366`) and `/sys/devices/system/node/node1` (`:370`) |
| `srt/distributed/device_communicators/custom_all_reduce_utils.py:354` `is_full_nvlink(ids, ws)` | pynvml `nvmlDeviceGetP2PStatus(..., NVML_P2P_CAPS_INDEX_NVLINK)` (`:381-383`) | Indirectly yes: the module binds `pynvml` only `if _is_cuda:` (`:30,34-36`), where `_is_cuda = is_cuda()` runs at import |
| `srt/utils/cuda_vmm_utils.py:162,189` `_gpu_fabric_clique` / `is_gpu_fabric_ready` | pynvml `nvmlDeviceGetGpuFabricInfoV` (v3) or `nvmlDeviceGetGpuFabricInfo` (`:171-183`) | Only if `CUDA_VISIBLE_DEVICES` is unset: then it calls `torch.cuda.device_count()` (`:170`) |
| `python3 -m sglang.check_env`, `GPUEnv.get_info` (`check_env.py:146-153`) | `torch.cuda.is_available()`, then `torch.cuda.get_device_name/get_device_capability` per device (`:86-110`), `nvidia-smi topo -m` (`:203-...`) | Yes for the GPU section |

### Every capability gate goes through torch.cuda

- `is_cuda()` = `torch.cuda.is_available() and torch.version.cuda is not None` (`srt/utils/common.py:156-157`).
- `is_sm100_supported`, `is_sm90_supported`, `is_blackwell_supported`, `is_sm120_supported`, `is_sm100_or_sm110_supported`
  are `partial(_check_cuda_device_version, ...)` (`common.py:275-320`), and `_check_cuda_device_version`
  returns False unless `is_cuda()`, then reads `torch.cuda.get_device_capability()[0]` (`common.py:264-272`).
- `get_platform().<fact>` (`srt/runtime_context.py:1857-1931`) maps every fact (`is_cuda`, `is_sm100`, `is_blackwell`,
  `device_sm`, `device_capability`, ...) to those same `utils.common` probes.
- Platform selection `_resolve_platform()` picks `CudaSRTPlatform` only if `torch.cuda.is_available()`
  (`srt/platforms/__init__.py:34-35,127-131`). `CudaDeviceMixin` answers memory/name/capability from
  `torch.cuda.get_device_properties` / `get_device_capability` (`srt/platforms/cuda.py:27-49`).
- SGLang does not set `PYTORCH_NVML_BASED_CUDA_CHECK` (vLLM does). The grep below could have matched, and the
  same grep finds vLLM's line:

```
$ grep -rn "PYTORCH_NVML_BASED_CUDA_CHECK" /tmp/vr200-llm-spike-58fc971e/taskB/sglang-v0.5.20 ; echo grep_rc=$?
grep_rc=1
$ grep -rn "PYTORCH_NVML_BASED_CUDA_CHECK" .../taskB/vllm-v0.30.0/vllm/env_override.py
.../vllm/env_override.py:164:os.environ["PYTORCH_NVML_BASED_CUDA_CHECK"] = "1"
```

  So in SGLang, `torch.cuda.is_available()` is torch's default `torch._C._cuda_getDeviceCount() > 0`
  (`T:torch_cuda___init__.py:169-187`). That is the CUDA runtime's `cudaGetDeviceCount`, which goes through `libcuda.so.1`.

Consequence: all of SGLang's capability-gated decisions go through torch.cuda, so they belong to rung 3.
Rung 2 calls the nvidia-smi and pynvml helpers in the table directly.

### Serve-path order (where the first hardware question is asked)

`launch_server` -> `ServerArgs.resolve_once()` -> `run_resolution_pipeline` (`srt/arg_groups/pipeline.py`).
`handle_missing_default_values` runs at pipeline line 145. With `--device` unset it calls `get_device()`
(`srt/arg_groups/serving_hook.py:591-596`). `get_device()` (`srt/utils/common.py:896-949`) tries, in order:
`is_cpu()` (only if `SGLANG_USE_CPU_ENGINE=1`), `torch.cuda.is_available()`, xpu, npu, hpu, musa, mps, and finally
`current_platform.get_device()`. On the base `SRTPlatform` that call raises `NotImplementedError`
(`srt/platforms/device_mixin.py:181-183`), which `get_device()` re-raises as
`RuntimeError("No accelerator (CUDA, XPU, HPU, NPU, MUSA, MPS) or platform plugin is available.")`.
`handle_gpu_memory_settings` (pipeline line 234, `get_device_memory_capacity`) comes later.
INFERENCE, to be tested in rung 4: if `torch.cuda.is_available()` is False in the pod, the server dies in
argument resolution with that RuntimeError. That happens before any model download or weight load.

### Flag check

`--disable-cuda-graph` still exists at v0.5.20, but it is deprecated. It is the only CLI entry point for the
`no_cli=True` field `disable_cuda_graph` (`srt/server_args.py:402-409`, `srt/arg_groups/fields/exec_.py:508`).
The replacement is `--cuda-graph-backend-{decode,prefill}=disabled`. I keep the brief's flag and confirm it
with `--help` in rung 4.

### MOCK_NVML_DEBUG coverage (affects "NVML calls observed")

`MOCK_NVML_DEBUG` logs most device getters, but not every call. Two `debugLog` functions check the same
variable: `pkg/gpu/mocknvml/bridge/helpers.go:103,110` and `pkg/gpu/mocknvml/engine/utils.go:22-26`.
Counting call sites at 8058e1c9 with
`grep -rn "debugLog(" pkg/gpu/mocknvml --include='*.go' | grep -v _test.go | grep -v "func debugLog"`
gives bridge 18 and engine 164, of which 119 are in `engine/device.go`. Logged calls include `nvmlDeviceGetName`,
`nvmlDeviceGetMemoryInfo(_v2)`, `nvmlDeviceGetCudaComputeCapability`, `nvmlDeviceGetP2PStatus`,
`nvmlDeviceGetMemoryAffinity`, `nvmlDeviceGetGpuFabricInfo(V)`, `nvmlDeviceGetHandleByIndex/UUID/PciBusId`, and
stubbed calls (`[NVML-STUB] <fn> called (NOT IMPLEMENTED|FUNCTION_NOT_FOUND ...)`, `bridge/helpers.go:145,151`).
Init and shutdown appear only as `[ENGINE]`/`[CONFIG]` lines. Device count, the system-level getters
(`bridge/system.go` has no `debugLog`) and `nvmlInitWithFlags(0)` (`bridge/init.go:47`) are not logged.
(Correction: my first pass searched `bridge/` only and wrongly concluded the getters were not logged. I sent that
to main at ~06:40Z and corrected it at ~06:52Z.) To cover the unlogged calls I also run the python processes under
`LD_DEBUG=bindings` (per-pid files) and keep the binding lines into `libnvidia-ml`. Rung 2 step 0 is the positive
control that shows this catches a ctypes `dlsym`.

## Rung 1: PASS

Script `d-rung1.sh`, log `d-rung1.log`, manifest `d-sglang-pod.yaml`. The pod is task A's `a-gpu-pod-manual.yaml`
recipe: hostPath `/var/lib/nvml-mock` read-only at `/opt/nvml-mock`, `PATH` and `LD_LIBRARY_PATH` set to the mock
dirs PREPENDED to the image's own values, `MOCK_NVML_CONFIG`, `MOCK_NVML_DEBUG=1`, `HF_HOME=/tmp/hf`. On top of
that: `nvidia.com/gpu: 4`, memory request 1Gi and limit 3Gi, an emptyDir `/opt/nvml-only` for the NVML-ONLY
exposure, a 1Gi memory emptyDir at `/dev/shm` (as in SGLang's own `docker/k8s-sglang-service.yaml`), and
`imagePullPolicy: Never`, so the pod cannot start a second pull. The pull finished before the pod was created
(`a-pull-sglang-worker2.log`: `=== 2026-09-23T07:19:55Z END ... PULL_RC=0`).

The image's own env comes from `crictl inspecti` on the node. It matches the registry config read earlier:

```
$ docker exec mokka-vr200-llm-worker2 bash -c 'crictl inspecti docker.io/lmsysorg/sglang:v0.5.20 | jq -r ".status.id, (.status.repoDigests|tostring), (.info.imageSpec.config.Env[] | select(test(\"^(PATH|LD_LIBRARY_PATH|CUDA_VERSION|SGLANG_BUILD_COMMIT)=\"))), (.info.imageSpec.config.Entrypoint|tostring)"'
sha256:3ec36384d5eadedb920086d6e1b874e0bedf1d7bb773d2f56c3ccbacbb26d7bb
["docker.io/lmsysorg/sglang@sha256:06e4f2ed21afde4ff513cda65070124e727ba23ccaeff7712b8c40e1097d611f"]
PATH=/root/.cargo/bin:/opt/sglang/bin:/usr/local/nvidia/bin:/usr/local/cuda/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/nvidia/bin
CUDA_VERSION=13.0.3
LD_LIBRARY_PATH=/usr/local/nvidia/lib:/usr/local/nvidia/lib64:/usr/local/cuda/lib64:/usr/local/nvidia/lib:/usr/local/nvidia/lib64
SGLANG_BUILD_COMMIT=94602c9c2b7cbdb8efd5c52802dac6a1c180089e
["/opt/nvidia/nvidia_entrypoint.sh"]
RC=0
```

```
$ kubectl --context kind-mokka-vr200-llm apply -f /tmp/vr200-llm-spike-58fc971e/d-sglang-pod.yaml
pod/sglang-ladder created
$ kubectl --context kind-mokka-vr200-llm -n spike-sglang wait --for=condition=Ready pod/sglang-ladder --timeout=300s
pod/sglang-ladder condition met
$ kubectl --context kind-mokka-vr200-llm -n spike-sglang get pod sglang-ladder -o wide
NAME            READY   STATUS    RESTARTS   AGE   IP           NODE                      NOMINATED NODE   READINESS GATES
sglang-ladder   1/1     Running   0          2s    10.244.3.4   mokka-vr200-llm-worker2   <none>           <none>
$ kubectl --context kind-mokka-vr200-llm -n spike-sglang get pod sglang-ladder -o jsonpath='{.status.containerStatuses[0].imageID}'
docker.io/lmsysorg/sglang@sha256:06e4f2ed21afde4ff513cda65070124e727ba23ccaeff7712b8c40e1097d611f
$ kubectl ... exec sglang-ladder -- bash -c 'env | grep -E "^(PATH|LD_LIBRARY_PATH|MOCK_NVML|NVIDIA_VISIBLE|CUDA_VISIBLE|HF_HOME)" | sort; ls -l /dev | grep -i nvidia'
HF_HOME=/tmp/hf
LD_LIBRARY_PATH=/opt/nvml-mock/driver/usr/lib64:/usr/local/nvidia/lib:/usr/local/nvidia/lib64:/usr/local/cuda/lib64:/usr/local/nvidia/lib:/usr/local/nvidia/lib64
MOCK_NVML_CONFIG=/opt/nvml-mock/driver/config/config.yaml
MOCK_NVML_DEBUG=1
NVIDIA_VISIBLE_DEVICES=GPU-307f0000-0000-0000-0000-000000000001,GPU-307f0000-0000-0000-0000-000000000002,GPU-307f0000-0000-0000-0000-000000000003,GPU-307f0000-0000-0000-0000-000000000000
PATH=/opt/nvml-mock/driver/usr/bin:/root/.cargo/bin:/opt/sglang/bin:/usr/local/nvidia/bin:/usr/local/cuda/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/nvidia/bin
crw-rw-rw- 1 root root 195, 0 Sep 23 07:20 nvidia0
crw-rw-rw- 1 root root 195, 1 Sep 23 07:20 nvidia1
crw-rw-rw- 1 root root 195, 2 Sep 23 07:20 nvidia2
crw-rw-rw- 1 root root 195, 3 Sep 23 07:20 nvidia3
$ kubectl ... exec sglang-ladder -- bash -c 'command -v nvidia-smi python3; nvidia-smi -L'
/opt/nvml-mock/driver/usr/bin/nvidia-smi
/opt/sglang/bin/python3
[CONFIG] Loaded YAML config: 4 devices, driver 615.23          <- MOCK_NVML_DEBUG stderr, trimmed
[ENGINE] Initialized with 4 devices (4 visible)
...
GPU 0: NVIDIA Graphics Device (UUID: GPU-307f0000-0000-0000-0000-000000000000)
GPU 1: NVIDIA Graphics Device (UUID: GPU-307f0000-0000-0000-0000-000000000001)
GPU 2: NVIDIA Graphics Device (UUID: GPU-307f0000-0000-0000-0000-000000000002)
GPU 3: NVIDIA Graphics Device (UUID: GPU-307f0000-0000-0000-0000-000000000003)
[ENGINE] Shutdown complete
RC=0
$ kubectl ... exec sglang-ladder -- bash -c 'nvidia-smi --query-gpu=name,memory.total,compute_cap,driver_version --format=csv'
...
[NVML] nvmlDeviceGetName -> NVIDIA Graphics Device
[NVML] nvmlDeviceGetMemoryInfo_v2 -> total=309237645312 reserved=1339031552 used=0
[NVML] nvmlDeviceGetCudaComputeCapability -> 10.7
... (x4)
name, memory.total [MiB], compute_cap, driver_version
NVIDIA Graphics Device, 294912 MiB, 10.7, 615.23
NVIDIA Graphics Device, 294912 MiB, 10.7, 615.23
NVIDIA Graphics Device, 294912 MiB, 10.7, 615.23
NVIDIA Graphics Device, 294912 MiB, 10.7, 615.23
RC=0
$ kubectl ... exec sglang-ladder -- bash -c 'python3 -c "import sglang; print(\"sglang\", sglang.__version__)"'
sglang 0.5.20
RC=0
```

The vr200 profile loaded (`[CONFIG] Loaded YAML config: 4 devices, driver 615.23`), not the A100 default.
The 4 allocated device nodes are present.

## Rung 2: PARTIAL

Script `d-rung2.sh`, log `d-rung2.log`, probe script `d-rung2-discovery.py` (in the pod as
`/tmp/d-rung2-discovery.py`, md5 `eb4492c6a31f1fa4b7f1506076893276`). FULL exposure (pod env as-is). Every python
process ran under `LD_DEBUG=bindings LD_DEBUG_OUTPUT=/tmp/ld/<tag>` so that the NVML symbols each process bound can
be listed per pid (see "NVML calls observed"). The SGLang imported is the image's
`/sgl-workspace/sglang/python/sglang/__init__.py`, version `0.5.20`.

Summary: SGLang's CUDA-free helpers read vr200 correctly through Mokka's nvidia-smi and NVML. Every helper gated
on `is_cuda()` reports "no CUDA" or raises instead, because `torch.cuda.is_available()` is False in this pod
(rung 3). SGLang's own `check_env` reports `CUDA available: False` and prints no GPU names or capabilities. It
does print the vr200 NVLink/NUMA topology, because that part comes from `nvidia-smi topo -m`.

Positive control: `LD_DEBUG=bindings` catches a ctypes `dlsym` into the mock:

```
$ kubectl ... exec sglang-ladder -- bash -c 'LD_DEBUG=bindings LD_DEBUG_OUTPUT=/tmp/ld/ctl python3 -c "import ctypes; l=ctypes.CDLL(\"libnvidia-ml.so.1\"); print(\"init\", l.nvmlInit_v2())"'
[CONFIG] Loaded YAML config: 4 devices, driver 615.23
...
[ENGINE] Initialized with 4 devices (4 visible)
init 0
$ kubectl ... exec sglang-ladder -- bash -c 'bash /tmp/d-ldpid.sh ctl'
ctl pid=107 first_binder=linux-vdso.so.1 nvml=[nvmlInit_v2 ]
```

### 2.1 `python3 -m sglang.check_env` (verbatim, GPU-relevant lines)

```
$ kubectl ... exec sglang-ladder -- bash -c 'LD_DEBUG=bindings LD_DEBUG_OUTPUT=/tmp/ld/checkenv timeout 300 python3 -m sglang.check_env'
Python: 3.12.3 (main, Aug 31 2026, 10:18:26) [GCC 13.3.0]
CUDA available: False
PyTorch: 2.13.0+cu130
sglang: 0.5.20
sglang-kernel: 0.4.7
flashinfer_python: 0.6.18
flashinfer_cubin: 0.6.18
flashinfer_jit_cache: 0.6.18+cu130
triton: 3.7.1
transformers: 5.12.1
(... other package versions trimmed ...)
NVIDIA Topology: 
	GPU0	GPU1	GPU2	GPU3	CPU Affinity	NUMA Affinity	GPU NUMA ID
GPU0	 X 	NV18	NV18	NV18	0-63	0		0
GPU1	NV18	 X 	NV18	NV18	0-63	0		0
GPU2	NV18	NV18	 X 	NV18	64-127	1		1
GPU3	NV18	NV18	NV18	 X 	64-127	1		1
(legend trimmed)
ulimit soft: 1073741816
RC=0
```

Because `CUDA available` is False, `GPUEnv.get_info` (`check_env.py:146-153`) prints no `GPU 0,1,2,3` name line,
no `Compute Capability` line, and no `CUDA_HOME`/`NVCC`/`CUDA Driver Version` lines. Per-pid NVML bindings for this
command: the check_env python process (pid 126) bound NO nvml symbol, and the `nvidia-smi topo -m` child (pid 160)
bound 13. So the GPU facts in the output come only from nvidia-smi.

### 2.2 CUDA-free helpers, called directly (`d-rung2-discovery.py A`, FULL)

```
$ kubectl ... exec sglang-ladder -- bash -c 'LD_DEBUG=bindings LD_DEBUG_OUTPUT=/tmp/ld/discA timeout 300 python3 /tmp/d-rung2-discovery.py A'
[maps after import sglang] torch.cuda.is_initialized=False libs=['/opt/nvml-mock/driver/usr/lib64/libcuda.so.615.23', '/opt/sglang/lib/python3.12/site-packages/nvidia/cu13/lib/libcudart.so.13', '/opt/sglang/lib/python3.12/site-packages/torchvision.libs/libcudart.faf08d9a.so.13']
--- PROBE common.get_nvgpu_memory_capacity()
RESULT common.get_nvgpu_memory_capacity() = 294912.0
--- PROBE common.get_device_sm_nvidia_smi()
RESULT common.get_device_sm_nvidia_smi() = (10, 7)
--- PROBE common.get_nvidia_driver_version_str()
RESULT common.get_nvidia_driver_version_str() = '615.23'
--- PROBE common.get_nvidia_driver_version()
RESULT common.get_nvidia_driver_version() = (615, 23)
--- PROBE os.path.isdir('/sys/devices/system/node/node1')
RESULT os.path.isdir('/sys/devices/system/node/node1') = False
--- PROBE envs.SGLANG_AUTO_NUMA_BIND
RESULT envs.SGLANG_AUTO_NUMA_BIND = True
--- PROBE envs.SGLANG_NUMA_BIND_V2
RESULT envs.SGLANG_NUMA_BIND_V2 = True
--- PROBE numa_utils._query_numa_node_for_gpu(0)
[NVML] nvmlDeviceGetHandleByIndex(0)
[NVML]   -> handle=0x47a701c0 ret=0
[NVML] nvmlDeviceGetMemoryAffinity -> [1]
RESULT numa_utils._query_numa_node_for_gpu(0) = []
--- PROBE numa_utils._query_numa_node_for_gpu(1)      -> NVML mask [1], RESULT []
--- PROBE numa_utils._query_numa_node_for_gpu(2)      -> NVML mask [2], RESULT []
--- PROBE numa_utils._query_numa_node_for_gpu(3)      -> NVML mask [2], RESULT []
--- PROBE cuda_vmm_utils.pynvml is not None
RESULT cuda_vmm_utils.pynvml is not None = True
--- PROBE cuda_vmm_utils.is_gpu_fabric_ready(cuda:0) [CVD unset]
[NVML] nvmlDeviceGetGpuFabricInfoV -> clique=32766 state=3 healthMask=0x1aa healthSummary=1
RESULT cuda_vmm_utils.is_gpu_fabric_ready(cuda:0) [CVD unset] = True
[maps after end] torch.cuda.is_initialized=False libs=['/opt/nvml-mock/driver/usr/lib64/libcuda.so.615.23', '/opt/nvml-mock/driver/usr/lib64/libnvidia-ml.so.615.23', '/opt/sglang/lib/python3.12/site-packages/nvidia/cu13/lib/libcudart.so.13', '/opt/sglang/lib/python3.12/site-packages/torchvision.libs/libcudart.faf08d9a.so.13']
RC=0
```

- nvidia-smi helpers: memory 294912 MiB (= 309237645312 / 2^20), compute capability (10, 7), and driver 615.23.
  All three are correct vr200 values.
- NUMA: the mock answers `nvmlDeviceGetMemoryAffinity` correctly: node mask `[1]` (node 0) for GPUs 0 and 1,
  `[2]` (node 1) for GPUs 2 and 3. That agrees with `nvidia-smi topo -m`. SGLang still returns `[]`, because it
  decodes the mask only over `range(numa_node_count)`, where
  `numa_node_count = len(glob("/sys/devices/system/node/node[0-9]*"))` (`numa_utils.py:414`). The pod has no
  NUMA sysfs at all:

  ```
  $ kubectl ... exec sglang-ladder -- bash -c 'ls /sys/devices/system/node/; echo "ls_rc=$?"; ls -d /sys/devices/system/cpu/cpu0; nproc'
  ls: cannot access '/sys/devices/system/node/': No such file or directory
  ls_rc=2
  /sys/devices/system/cpu/cpu0            <- positive control: /sys/devices/system is there
  14
  ```

  This comes from the kind/linuxkit node's kernel sysfs, not from Mokka's NVML. The manual injection recipe
  does not mount a rendered `/sys` tree. INFERENCE: task B says Mokka's CDI mode bind-mounts one over
  `/sys/devices`. I did not test that here. The NUMA auto-bind path is off anyway, because `_is_numa_available()`
  needs `_is_cuda` (`numa_utils.py:366`).
- Fabric: `is_gpu_fabric_ready` is True for every GPU. `_gpu_fabric_clique` returns cluster UUID
  `...0001` and clique 32766 (state 3 = COMPLETED), which is the vr200 fabric.
  With `CUDA_VISIBLE_DEVICES` unset the helper calls `torch.cuda.device_count()` (`cuda_vmm_utils.py:170`),
  and that did NOT fail. The python process (pid 174) bound `nvmlInit` and `nvmlDeviceGetCount_v2`, which is
  torch's own NVML-based count. So `torch.cuda.device_count()` is 4 through Mokka's NVML even while
  `torch.cuda.is_available()` is False (rung 3 shows both).

### 2.3 Fabric with `CUDA_VISIBLE_DEVICES=0,1,2,3` (`... A2`)

```
$ kubectl ... exec sglang-ladder -- bash -c 'CUDA_VISIBLE_DEVICES=0,1,2,3 LD_DEBUG=bindings LD_DEBUG_OUTPUT=/tmp/ld/discA2 timeout 300 python3 /tmp/d-rung2-discovery.py A2'
RESULT cuda_vmm_utils.is_gpu_fabric_ready(cuda:0) [CVD set] = True     (same for cuda:1..3)
RESULT cuda_vmm_utils._gpu_fabric_clique(cuda:0) [CVD set] = (b'\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01', 32766)   (same for cuda:1..3)
RC=0
```

### 2.4 Custom all-reduce NVLink check (`... A3`)

```
$ kubectl ... exec sglang-ladder -- bash -c 'LD_DEBUG=bindings LD_DEBUG_OUTPUT=/tmp/ld/discA3 timeout 300 python3 /tmp/d-rung2-discovery.py A3'
RESULT car._is_cuda = False
RESULT 'pynvml' in car.__dict__ = False
--- PROBE car.is_full_nvlink([0,1,2,3], 4) [unmodified]
EXC car.is_full_nvlink([0,1,2,3], 4) [unmodified]: NameError: name 'pynvml' is not defined
  File "/sgl-workspace/sglang/python/sglang/srt/distributed/device_communicators/custom_all_reduce_utils.py", line 344, in wrapper
    pynvml.nvmlInit()
NameError: name 'pynvml' is not defined
DIAGNOSTIC: harness bound car.pynvml = pynvml (SGLang skipped it because _is_cuda was False)
[NVML] nvmlDeviceGetP2PStatus(0,1) -> OK (nvlink)
[NVML] nvmlDeviceGetP2PStatus(0,2) -> OK (nvlink)
[NVML] nvmlDeviceGetP2PStatus(0,3) -> OK (nvlink)
[NVML] nvmlDeviceGetP2PStatus(1,2) -> OK (nvlink)
[NVML] nvmlDeviceGetP2PStatus(1,3) -> OK (nvlink)
[NVML] nvmlDeviceGetP2PStatus(2,3) -> OK (nvlink)
RESULT car.is_full_nvlink([0,1,2,3], 4) [DIAGNOSTIC pynvml bound] = True
RESULT car.is_full_nvlink([0,1], 2) [DIAGNOSTIC pynvml bound] = True
RC=0
```

Unmodified, SGLang's NVLink check cannot run in this pod. The module imports `pynvml` only when
`_is_cuda` is True, and it is False. The DIAGNOSTIC line is my harness, not SGLang: I bound the module global
that SGLang skipped. With that binding, SGLang's own loop concludes "fully NVLink-connected" from Mokka's
`nvmlDeviceGetP2PStatus` answers.

### 2.5 Libraries mapped before any CUDA call

`import sglang` alone maps Mokka's `libcuda.so.615.23`, the pip CUDA 13 runtime
(`site-packages/nvidia/cu13/lib/libcudart.so.13`) and torchvision's bundled `libcudart.faf08d9a.so.13`, with
`torch.cuda.is_initialized=False` (`[maps after import sglang]` line above). The Go mock `libnvidia-ml` is
not mapped until the first pynvml or nvidia-smi use. Rung 3 shows who loads libcuda.

## Rung 2b: SGLang discovery with `PYTORCH_NVML_BASED_CUDA_CHECK=1` (chief's added experiment)

Script `d-rung2b.sh`, log `d-rung2b.log` (pod recreated at ~08:05Z from the same manifest; image and env unchanged).
The same probe script (md5 `eb4492c6a31f1fa4b7f1506076893276`), with the one env var added. Per-pid NVML bindings
via `LD_DEBUG=bindings`.

### Side by side: SGLang's own view, default vs env var (FULL; NVML-ONLY gives identical values in both columns)

| SGLang probe | Default (rung 3.5) | `PYTORCH_NVML_BASED_CUDA_CHECK=1` (rung 2b) |
|---|---|---|
| `torch.cuda.is_available()` | `False` | `True` |
| `common.is_cuda()` | `False` | `True` |
| `common.get_device_memory_capacity('cuda')` | `None` | `294912.0` (nvidia-smi child, pid 318, bound `nvmlDeviceGetMemoryInfo_v2`) |
| `common.get_device()` | `RuntimeError: No accelerator (...)` | `'cuda'` |
| `common.get_device_count()` | `0` | `4` |
| `sglang.srt.platforms.current_platform` | `'SRTPlatform'` | `'CudaSRTPlatform'` |
| `get_platform().has_flashinfer` | `False` | `True` |
| `custom_all_reduce_utils.is_full_nvlink([0,1,2,3], 4)`, UNMODIFIED | `NameError: name 'pynvml' is not defined` | `True` (6x `nvmlDeviceGetP2PStatus(i,j) -> OK (nvlink)`) |
| `common.get_device_sm()` | `0` | `RuntimeError: Found no NVIDIA driver on your system...` |
| `common.get_device_capability(0)` | `(None, None)` | `RuntimeError: Found no NVIDIA driver...` |
| `common.get_device_name(0)` | `None` | `RuntimeError: Found no NVIDIA driver...` |
| `get_platform().is_sm90` / `is_sm100` / `is_sm100_or_sm110` / `is_sm120` / `is_blackwell` | `False` each | `RuntimeError: Found no NVIDIA driver...` each |
| `get_platform().device_sm` / `device_capability` | `0` / `(None, None)` | `RuntimeError: Found no NVIDIA driver...` |
| `python3 -m sglang.check_env` | prints `CUDA available: False` and the NV18 topology | crashes: `check_env.py:93 get_device_info` -> `torch.cuda.get_device_name(k)` -> `RuntimeError: Found no NVIDIA driver on your system...` |

Verbatim (FULL, trimmed to probe lines):

```
$ kubectl ... exec sglang-ladder -- bash -c 'rm -f /tmp/ld/b2full.*; PYTORCH_NVML_BASED_CUDA_CHECK=1 LD_DEBUG=bindings LD_DEBUG_OUTPUT=/tmp/ld/b2full timeout 300 python3 /tmp/d-rung2-discovery.py B 2>&1 | grep -v ...'
[CONFIG] Loaded YAML config: 4 devices, driver 615.23
[ENGINE] Initialized with 4 devices (4 visible)
RESULT torch.cuda.is_available() = True
RESULT common.is_cuda() = True
RESULT common.get_device_memory_capacity('cuda') = 294912.0
RESULT common.get_device() = 'cuda'
RESULT common.get_device_count() = 4
EXC common.get_device_sm(): RuntimeError: Found no NVIDIA driver on your system. Please check that you have an NVIDIA GPU and installed a driver from http://www.nvidia.com/Download/index.aspx
EXC common.get_device_capability(0): RuntimeError: Found no NVIDIA driver on your system. ...
EXC common.get_device_name(0): RuntimeError: Found no NVIDIA driver on your system. ...
RESULT get_platform().is_cuda = True
EXC get_platform().is_sm90: RuntimeError: Found no NVIDIA driver on your system. ...
EXC get_platform().is_sm100: RuntimeError: Found no NVIDIA driver on your system. ...
EXC get_platform().is_blackwell: RuntimeError: Found no NVIDIA driver on your system. ...
RESULT get_platform().has_flashinfer = True
EXC get_platform().device_capability: RuntimeError: Found no NVIDIA driver on your system. ...
RESULT sglang.srt.platforms.current_platform = 'CudaSRTPlatform'
$ kubectl ... exec sglang-ladder -- bash -c 'bash /tmp/d-ldpid.sh b2full'
b2full pid=276 ... nvml=[]                                              <- timeout
b2full pid=278 ... nvml=[nvmlDeviceGetCount_v2 nvmlInit ]               <- python (torch's NVML count)
b2full pid=318 ... nvml=[nvmlDeviceGetCount_v2 nvmlDeviceGetHandleByIndex_v2 nvmlDeviceGetMemoryInfo_v2 nvmlInitWithFlags nvmlInternalGetExportTable nvmlShutdown ]   <- nvidia-smi
$ kubectl ... exec sglang-ladder -- bash -c 'PYTORCH_NVML_BASED_CUDA_CHECK=1 ... python3 /tmp/d-rung2-discovery.py A3 ...'
RESULT car._is_cuda = True
RESULT 'pynvml' in car.__dict__ = True
[NVML] nvmlDeviceGetP2PStatus(0,1) -> OK (nvlink)      (and 0,2 0,3 1,2 1,3 2,3)
RESULT car.is_full_nvlink([0,1,2,3], 4) [unmodified] = True
$ kubectl ... exec sglang-ladder -- bash -c 'PYTORCH_NVML_BASED_CUDA_CHECK=1 timeout 300 python3 -m sglang.check_env 2>&1 | ... | tail -25'
  File "/sgl-workspace/sglang/python/sglang/check_env.py", line 93, in get_device_info
    devices[torch.cuda.get_device_name(k)].append(str(k))
  ...
  File "/opt/sglang/lib/python3.12/site-packages/torch/cuda/__init__.py", line 529, in _lazy_init
    torch._C._cuda_init()
RuntimeError: Found no NVIDIA driver on your system. Please check that you have an NVIDIA GPU and installed a driver from http://www.nvidia.com/Download/index.aspx
```

NVML-ONLY with the env var (`d-rung2b.log`, 08:07:22Z) gives the same RESULT/EXC lines value for value, including
`294912.0`, `4`, `'CudaSRTPlatform'`, and the same RuntimeErrors.

Reading: the one env var moves SGLang from "no accelerator" to "4 CUDA GPUs, 294912 MiB each, fully
NVLink-connected, CUDA platform, FlashInfer available". All of that comes from Mokka's NVML and nvidia-smi.
It does NOT give SGLang the compute capability, the device name or any SM gate. Those come from
`torch.cuda.get_device_properties`, i.e. the CUDA runtime, and they raise. SGLang never reads CC 10.7 or
"NVIDIA Graphics Device" through its own code, even with the env var.

## Rung 3: FAIL (both exposures, same error)

Script `d-rung3.sh` plus two follow-up diagnostics, all logged in `d-rung3.log`. Probe scripts:
`d-rung3-torch.py` (the LADDER statements plus `/proc/self/maps`) and `d-rung3-who.py`.

### 3.1 Library landscape in the image

```
$ kubectl ... exec sglang-ladder -- bash -c 'ldconfig -p | grep -E "libcuda|libcudart|libnvidia-ml"; echo "ldconfig_grep_rc=$?"'
	libcudart.so.13 (libc6,AArch64) => /usr/local/cuda/targets/sbsa-linux/lib/libcudart.so.13
	libcudart.so (libc6,AArch64) => /usr/local/cuda/targets/sbsa-linux/lib/libcudart.so
ldconfig_grep_rc=0
$ kubectl ... exec sglang-ladder -- bash -c 'find / -xdev \( -name "libcuda.so*" -o -name "libcudart.so*" -o -name "libnvidia-ml.so*" \) 2>/dev/null | sort'
/opt/sglang/lib/python3.12/site-packages/nvidia/cu13/lib/libcudart.so.13
/usr/local/cuda-13.0/compat/libcuda.so
/usr/local/cuda-13.0/compat/libcuda.so.1
/usr/local/cuda-13.0/compat/libcuda.so.580.126.20
/usr/local/cuda-13.0/targets/sbsa-linux/lib/libcudart.so
/usr/local/cuda-13.0/targets/sbsa-linux/lib/libcudart.so.13
/usr/local/cuda-13.0/targets/sbsa-linux/lib/libcudart.so.13.0.96
/usr/local/cuda-13.0/targets/sbsa-linux/lib/stubs/libcuda.so
/usr/local/cuda-13.0/targets/sbsa-linux/lib/stubs/libnvidia-ml.so
$ kubectl ... exec sglang-ladder -- bash -c 'T=$(python3 -c "import torch,os; print(os.path.dirname(torch.__file__))"); readelf -d $T/lib/libtorch_cuda.so | grep -E "NEEDED|RPATH|RUNPATH"'
 (NEEDED) Shared library: [libcudart.so.13]      (plus cublas/cudnn/nccl/... ; no libcuda)
 (RPATH)  Library rpath: [$ORIGIN/../../nvidia/cudnn/lib:$ORIGIN/../../nvidia/nvshmem/lib:$ORIGIN/../../nvidia/nccl/lib:$ORIGIN/../../nvidia/cusparselt/lib:$ORIGIN/../../nvidia/cu13/lib:$ORIGIN]
```

- torch is `2.13.0+cu130`. It needs `libcudart.so.13` and finds it through DT_RPATH, which the loader searches
  BEFORE `LD_LIBRARY_PATH`. Mokka's `libcudart.so.12 -> libcuda.so.1` symlink therefore never shadows torch's
  runtime: it is the wrong major (12), and the RPATH lookup wins anyway.
- The image carries a CUDA forward-compat driver (`/usr/local/cuda-13.0/compat/libcuda.so.580.126.20`), but no
  ld.so config line or env var puts `compat/` on the search path, so the loader never tries it (3.3 shows this).
  INFERENCE, not tested: the image's `/opt/nvidia/nvidia_entrypoint.sh` may enable compat. The pod's `command:`
  replaces the entrypoint, so it never ran here.

### 3.2 (a) FULL exposure (`LD_LIBRARY_PATH=/opt/nvml-mock/driver/usr/lib64:<image>`)

The LADDER command, verbatim:

```
$ kubectl --context kind-mokka-vr200-llm -n spike-sglang exec sglang-ladder -- bash -c 'python3 -c 'import torch; print(torch.__version__, torch.version.cuda); print("avail", torch.cuda.is_available()); print("count", torch.cuda.device_count()); x = torch.zeros(1, device="cuda"); print("alloc ok", x)''
[CONFIG] Loaded YAML config: 4 devices, driver 615.23      <- from torch.cuda.device_count() (NVML), trimmed
[ENGINE] Initialized with 4 devices (4 visible)
Traceback (most recent call last):
  File "<string>", line 1, in <module>
  File "/opt/sglang/lib/python3.12/site-packages/torch/cuda/__init__.py", line 529, in _lazy_init
    torch._C._cuda_init()
RuntimeError: Found no NVIDIA driver on your system. Please check that you have an NVIDIA GPU and installed a driver from http://www.nvidia.com/Download/index.aspx
2.13.0+cu130 13.0
avail False
count 4
command terminated with exit code 1
RC=1
```

The same process under `LD_DEBUG=libs` (loader order kept, pid prefix stripped):

```
find library=libcudart.so.13 [0]; searching
  trying file=/opt/sglang/lib/python3.12/site-packages/torch/lib/../../nvidia/cudnn/lib/libcudart.so.13
  ... (nvshmem, nccl, cusparselt)
  trying file=/opt/sglang/lib/python3.12/site-packages/torch/lib/../../nvidia/cu13/lib/libcudart.so.13
calling init: /opt/sglang/lib/python3.12/site-packages/torch/lib/../../nvidia/cu13/lib/libcudart.so.13
find library=libcuda.so.1 [0]; searching
  trying file=/opt/nvml-mock/driver/usr/lib64/libcuda.so.1
calling init: /opt/nvml-mock/driver/usr/lib64/libcuda.so.1
[maps final] ['/opt/nvml-mock/driver/usr/lib64/libcuda.so.615.23', '/opt/nvml-mock/driver/usr/lib64/libnvidia-ml.so.615.23', '/opt/sglang/lib/python3.12/site-packages/nvidia/cu13/lib/libcudart.so.13']
```

Who loads Mokka's libcuda, and when (`LD_DEBUG=files`, `d-rung3-who.py`): it happens during `import torch`, and
the loader is cuBLASLt, not cudart:

```
file=libcudart.so.13 [0];  needed by /opt/sglang/lib/python3.12/site-packages/torch/lib/libtorch_global_deps.so [0]
calling init: /opt/sglang/lib/python3.12/site-packages/torch/lib/../../nvidia/cu13/lib/libcudart.so.13
file=libcuda.so.1 [0];  dynamically loaded by /opt/sglang/lib/python3.12/site-packages/nvidia/cu13/lib/libcublasLt.so.13 [0]
calling init: /opt/nvml-mock/driver/usr/lib64/libcuda.so.1
...
calling fini: /opt/nvml-mock/driver/usr/lib64/libcuda.so.1 [0]          <- at process exit
```

Which CUDA driver-API symbols the process looked for in Mokka's libcuda, and which it got
(`LD_DEBUG=symbols,bindings` on `import torch; torch.cuda.is_available()`):

```
$ ... grep -h "lookup in file=/opt/nvml-mock/driver/usr/lib64/libcuda.so.1" /tmp/ld/r3sym.* | grep -o "symbol=cu[A-Za-z0-9_]*" | ... first-seen order, first 40
cuInit cuDriverGetVersion cuLinkCreate_v2 cuLinkAddData_v2 cuLinkComplete cuModuleLoadData cuModuleUnload
cuGetErrorString cuLinkDestroy cuModuleGetFunction cuFuncSetAttribute cuFuncGetAttribute cuLaunchKernel
cuGetErrorName cuModuleLoadFatBinary cuModuleLoadDataEx cuLinkAddFile_v2 cuCtxPushCurrent cuCtxPopCurrent
cuCtxGetDevice cuCtxGetLimit cuDevicePrimaryCtxRetain cuDevicePrimaryCtxRelease cuDevicePrimaryCtxReset
cuDeviceGet cuDeviceGetAttribute cuStreamSynchronize cuOccupancyMaxActiveBlocksPerMultiprocessor
cuTensorMapEncodeTiled cuLaunchKernelEx cuMemcpyDtoH_v2 cuModuleGetGlobal_v2 cuGetProcAddress_v2
cuGetProcAddress cuDeviceGetCount cuDeviceGetName cuDeviceTotalMem_v2 cuDeviceGetP2PAttribute
cuDeviceGetHostAtomicCapabilities cuDeviceGetP2PAtomicCapabilities
--- cu* symbols BOUND to Mokka libcuda.so.1:
      3 cuInit
```

Of every driver entry point looked up, only `cuInit` resolves in Mokka's libcuda. `cuDriverGetVersion`,
`cuGetProcAddress_v2`/`cuGetProcAddress` and `cuDeviceGetCount` are all looked up and not found.
These lookup lines do not name the caller. Section 3.6 does: the `cuGetProcAddress*` and `cuDeviceGetCount`
lookups come from torch's `libcudart.so.13`. INFERENCE: without them cudart cannot enumerate devices, and torch
turns that into "Found no NVIDIA driver on your system" (`device_count_ensure_non_zero`).

Both Go runtimes sit in one python process (Mokka's libcuda from `import torch`, Mokka's libnvidia-ml from
`torch.cuda.device_count()`). No crash or hang was observed in this or any other rung-2/3 run. The failure is a
clean Python `RuntimeError`.

`torch.cuda.device_count()` returns 4 while `torch.cuda.is_available()` returns False. torch 2.13 counts devices
through NVML (Mokka answers: `[ENGINE] Initialized with 4 devices`), but decides availability through the CUDA
runtime. SGLang uses the second.

### 3.3 (b) NVML-ONLY exposure (`LD_LIBRARY_PATH=/opt/nvml-only:<image>`, only `libnvidia-ml.so*` copied there)

```
$ kubectl ... exec sglang-ladder -- bash -c 'cp -a /opt/nvml-mock/driver/usr/lib64/libnvidia-ml.so* /opt/nvml-only/ && ls -l /opt/nvml-only/'
lrwxrwxrwx 1 root root       17 Sep 23 07:25 libnvidia-ml.so -> libnvidia-ml.so.1
lrwxrwxrwx 1 root root       22 Sep 23 07:25 libnvidia-ml.so.1 -> libnvidia-ml.so.615.23
-rwxr-xr-x 1 root root 14123928 Sep 23 07:25 libnvidia-ml.so.615.23
$ kubectl ... exec sglang-ladder -- bash -c 'LD_LIBRARY_PATH=/opt/nvml-only:/usr/local/nvidia/lib:/usr/local/nvidia/lib64:/usr/local/cuda/lib64:/usr/local/nvidia/lib:/usr/local/nvidia/lib64 python3 -c '<LADDER statements>''
[ENGINE] Initialized with 4 devices (4 visible)
Traceback (most recent call last):
  File "/opt/sglang/lib/python3.12/site-packages/torch/cuda/__init__.py", line 529, in _lazy_init
    torch._C._cuda_init()
RuntimeError: Found no NVIDIA driver on your system. Please check that you have an NVIDIA GPU and installed a driver from http://www.nvidia.com/Download/index.aspx
2.13.0+cu130 13.0
avail False
count 4
command terminated with exit code 1
RC=1
```

`LD_DEBUG=libs` for the same exposure: `libcuda.so.1` is searched three times and found nowhere. The mock is not
on the path, and the image's `compat/` copy is not on it either:

```
find library=libcuda.so.1 [0]; searching
  trying file=/opt/nvml-only/libcuda.so.1
  trying file=/usr/local/cuda/lib64/libcuda.so.1
  trying file=/opt/sglang/lib/python3.12/site-packages/nvidia/cu13/lib/libcuda.so.1
  trying file=/lib/aarch64-linux-gnu/libcuda.so.1
  trying file=/usr/lib/aarch64-linux-gnu/libcuda.so.1
  trying file=/lib/libcuda.so.1
  trying file=/usr/lib/libcuda.so.1
(two more searches over the torch RPATH dirs and the same system dirs, all misses)
[maps final] ['/opt/nvml-only/libnvidia-ml.so.615.23', '/opt/sglang/lib/python3.12/site-packages/nvidia/cu13/lib/libcudart.so.13']
```

`nvidia-smi -L` under NVML-ONLY still lists the 4 vr200 GPUs (its own RPATH `$ORIGIN/../lib64`).

### 3.4 Side by side

| | (a) FULL | (b) NVML-ONLY |
|---|---|---|
| libcudart loaded | `site-packages/nvidia/cu13/lib/libcudart.so.13` (torch RPATH) | same |
| libcuda.so.1 loaded | Mokka shim `/opt/nvml-mock/driver/usr/lib64/libcuda.so.615.23`, dlopened by `libcublasLt.so.13` at `import torch` | none (not found; compat copy not on path) |
| driver symbols resolved | `cuInit` only | none |
| `torch.cuda.is_available()` | False | False |
| `torch.cuda.device_count()` | 4 (NVML) | 4 (NVML) |
| `torch.zeros(1, device="cuda")` | `RuntimeError: Found no NVIDIA driver on your system...` | identical |

### 3.5 SGLang's torch-gated discovery (`d-rung2-discovery.py B`), identical under FULL and NVML-ONLY

```
RESULT torch.cuda.is_available() = False
RESULT common.is_cuda() = False
RESULT common.get_device_memory_capacity('cuda') = None
EXC common.get_device(): RuntimeError: No accelerator (CUDA, XPU, HPU, NPU, MUSA, MPS) or platform plugin is available.
  File "/sgl-workspace/sglang/python/sglang/srt/utils/common.py", line 945, in get_device
    return current_platform.get_device(device_id)
  File "/sgl-workspace/sglang/python/sglang/srt/platforms/device_mixin.py", line 183, in get_device
    raise NotImplementedError
RESULT common.get_device_count() = 0
RESULT common.get_device_sm() = 0
RESULT common.get_device_capability(0) = (None, None)
RESULT common.get_device_name(0) = None
RESULT get_platform().is_cuda = False
RESULT get_platform().is_sm90 = False
RESULT get_platform().is_sm100 = False
RESULT get_platform().is_sm100_or_sm110 = False
RESULT get_platform().is_sm120 = False
RESULT get_platform().is_blackwell = False
RESULT get_platform().has_flashinfer = False
RESULT get_platform().device_sm = 0
RESULT get_platform().device_capability = (None, None)
RESULT sglang.srt.platforms.current_platform = 'SRTPlatform'
```

SGLang's own view of this pod: no CUDA, device count 0, SM 0, not Blackwell, not SM100, and the base
`SRTPlatform` (not `CudaSRTPlatform`). The pod is really a vr200 profile at CC 10.7 with 4 GPUs.

One variance, unexplained: in the first FULL run of phase B (07:34Z) `/proc/self/maps` showed no Mokka libcuda
after `is_available()`. In two re-runs (07:38Z) and in every other FULL process it was mapped. The outcome
(`is_available() = False`) was the same every time. INFERENCE: cuBLASLt's dlopen may be timing-dependent. I did
not chase it.

### 3.6 Exact driver symbols and which .so asked (chief follow-up)

Two throwaway LD_PRELOAD tracers, compiled in the pod with the image's gcc 13.3. Both only log and forward to
glibc. `d-dltrace.c` wraps `dlsym` and logs `cu*`/`nvml*` names with the handle's library, the calling .so
(`dladdr` on the return address) and FOUND/NULL. It does not wrap `dlopen`, so the loader's search order is
unchanged. `d-dltrace-open.c` wraps `dlopen` only, to name the requester of each `libcuda.so.1` load. Caveat:
while it is preloaded, it is the dlopen caller, so the requester's DT_RPATH is not searched. The unwrapped
`LD_DEBUG=libs` run (3.3) shows those RPATH dirs hold no `libcuda.so.1`, so the outcome is unchanged.

Positive control (pynvml's ctypes lookups are seen):

```
$ kubectl ... exec sglang-ladder -- bash -c 'LD_PRELOAD=/tmp/libdltrace.so python3 -c "import pynvml; pynvml.nvmlInit(); print(\"count\", pynvml.nvmlDeviceGetCount()); pynvml.nvmlShutdown()" 2>&1 | grep -E "DLTRACE|^count"'
[DLTRACE] dlsym(/opt/nvml-mock/driver/usr/lib64/libnvidia-ml.so.1, "nvmlInitWithFlags") by /usr/lib/python3.12/lib-dynload/_ctypes.cpython-312-aarch64-linux-gnu.so -> FOUND
[DLTRACE] dlsym(/opt/nvml-mock/driver/usr/lib64/libnvidia-ml.so.1, "nvmlDeviceGetCount_v2") by /usr/lib/python3.12/lib-dynload/_ctypes.cpython-312-aarch64-linux-gnu.so -> FOUND
[DLTRACE] dlsym(/opt/nvml-mock/driver/usr/lib64/libnvidia-ml.so.1, "nvmlShutdown") by /usr/lib/python3.12/lib-dynload/_ctypes.cpython-312-aarch64-linux-gnu.so -> FOUND
count 4
```

Who loads libcuda.so.1 (the LADDER statements, `import torch; torch.cuda.is_available()`), per exposure:

```
$ kubectl ... exec sglang-ladder -- bash -c 'LD_PRELOAD=/tmp/libdltrace-open.so python3 -c "import torch; print(\"avail\", torch.cuda.is_available())" 2>&1 | grep -E "DLTRACE|avail|preload"; echo "--- same, NVML-ONLY:"; LD_LIBRARY_PATH=/opt/nvml-only:<image> LD_PRELOAD=/tmp/libdltrace-open.so python3 -c "..." 2>&1 | grep ...'
[DLTRACE] dlopen("libcuda.so.1") by /opt/sglang/lib/python3.12/site-packages/nvidia/cu13/lib/libcublasLt.so.13 -> OK
[DLTRACE] dlopen("/opt/sglang/lib/python3.12/site-packages/nvidia/cu13/lib/libcudart.so.13") by /usr/lib/python3.12/lib-dynload/_ctypes.cpython-312-aarch64-linux-gnu.so -> OK
[DLTRACE] dlopen("libcuda.so.1") by /opt/sglang/lib/python3.12/site-packages/nvidia/cusparselt/lib/libcusparseLt.so.0 -> OK
[DLTRACE] dlopen("libcuda.so.1") by /opt/sglang/lib/python3.12/site-packages/torch/lib/../../nvidia/cu13/lib/libcudart.so.13 -> OK
avail False
--- same, NVML-ONLY:
[DLTRACE] dlopen("libcuda.so.1") by /opt/sglang/lib/python3.12/site-packages/nvidia/cu13/lib/libcublasLt.so.13 -> NULL
[DLTRACE] dlopen("/opt/sglang/lib/python3.12/site-packages/nvidia/cu13/lib/libcudart.so.13") by /usr/lib/python3.12/lib-dynload/_ctypes.cpython-312-aarch64-linux-gnu.so -> OK
[DLTRACE] dlopen("libcuda.so.1") by /opt/sglang/lib/python3.12/site-packages/nvidia/cusparselt/lib/libcusparseLt.so.0 -> NULL
[DLTRACE] dlopen("libcuda.so.1") by /opt/sglang/lib/python3.12/site-packages/torch/lib/../../nvidia/cu13/lib/libcudart.so.13 -> NULL
[DLTRACE] dlopen("libnvidia-ml.so.1") by /usr/lib/python3.12/lib-dynload/_ctypes.cpython-312-aarch64-linux-gnu.so -> OK
avail False
count 4
```

(The `libcudart.so.13` line matches the tracer's `libcuda` substring filter. It is torch's ctypes preload of
cudart and succeeded (`-> OK`) in both exposures.)

Which driver symbols each .so asked Mokka's libcuda for (FULL, LADDER statements, `d-dltrace.c`), grouped:

| Requesting .so | dlsym calls on Mokka `libcuda.so.1` | FOUND | NULL | First lookups, in order |
|---|---|---|---|---|
| `nvidia/cu13/lib/libcublasLt.so.13` | 32 | 1 (`cuInit`) | 31 | `cuInit` FOUND, `cuDriverGetVersion` NULL, `cuLinkCreate_v2` NULL, `cuLinkAddData_v2` NULL, ... `cuModuleGetGlobal_v2` NULL |
| `nvidia/cusparselt/lib/libcusparseLt.so.0` | 32 | 1 (`cuInit`) | 31 | same 32 names, same results |
| `nvidia/cu13/lib/libcudart.so.13` (torch's runtime) | 441 (440 distinct names) | 1 (`cuInit`) | 440 (439 distinct names) | `cuGetProcAddress_v2` NULL, `cuInit` FOUND, `cuGetProcAddress` NULL, `cuGetProcAddress_v2` NULL, `cuDeviceGet` NULL, `cuDeviceGetCount` NULL, `cuDeviceGetName` NULL, `cuDeviceTotalMem_v2` NULL, `cuDeviceGetAttribute` NULL, ... `cuDriverGetVersion` NULL, ... |

```
[DLTRACE] dlsym(/opt/nvml-mock/driver/usr/lib64/libcuda.so.1, "cuGetProcAddress_v2") by /opt/sglang/lib/python3.12/site-packages/torch/lib/../../nvidia/cu13/lib/libcudart.so.13 -> NULL
[DLTRACE] dlsym(/opt/nvml-mock/driver/usr/lib64/libcuda.so.1, "cuInit") by /opt/sglang/lib/python3.12/site-packages/torch/lib/../../nvidia/cu13/lib/libcudart.so.13 -> FOUND
[DLTRACE] dlsym(/opt/nvml-mock/driver/usr/lib64/libcuda.so.1, "cuGetProcAddress") by /opt/sglang/lib/python3.12/site-packages/torch/lib/../../nvidia/cu13/lib/libcudart.so.13 -> NULL
[DLTRACE] dlsym(/opt/nvml-mock/driver/usr/lib64/libcuda.so.1, "cuGetProcAddress_v2") by /opt/sglang/lib/python3.12/site-packages/torch/lib/../../nvidia/cu13/lib/libcudart.so.13 -> NULL
[DLTRACE] dlsym(/opt/nvml-mock/driver/usr/lib64/libcuda.so.1, "cuDeviceGet") by /opt/sglang/lib/python3.12/site-packages/torch/lib/../../nvidia/cu13/lib/libcudart.so.13 -> NULL
[DLTRACE] dlsym(/opt/nvml-mock/driver/usr/lib64/libcuda.so.1, "cuDeviceGetCount") by /opt/sglang/lib/python3.12/site-packages/torch/lib/../../nvidia/cu13/lib/libcudart.so.13 -> NULL
...
```

Counts from the FULL block of `d-rung2b.log` (per requester: calls / FOUND / NULL / distinct names / distinct NULL names):

```
libcublasLt.so.13 calls=32 found=1 null=31 distinct=32 distinct_null=31
libcusparseLt.so.0 calls=32 found=1 null=31 distinct=32 distinct_null=31
libcudart.so.13 calls=441 found=1 null=440 distinct=440 distinct_null=439
cudart, first six: cuGetProcAddress_v2 NULL;cuInit FOUND;cuGetProcAddress NULL;cuGetProcAddress_v2 NULL;cuDeviceGet NULL;cuDeviceGetCount NULL;
```

In NVML-ONLY the tracer logs no `dlsym` into a libcuda at all, because every `dlopen("libcuda.so.1")` returned NULL.

No error message names a symbol. torch reports only "Found no NVIDIA driver on your system". The precise
"before" picture:
- FULL: the first missing symbol is `cuGetProcAddress_v2`, asked for by torch's `libcudart.so.13`. That is its
  very first lookup. Of the 440 distinct driver names cudart asks for, only `cuInit` resolves; the other 439
  return NULL, including `cuGetProcAddress`, `cuDeviceGetCount` and `cuDriverGetVersion`.
  cuBLASLt and cuSPARSELt each find only `cuInit` and miss `cuDriverGetVersion` onward.
- NVML-ONLY: `dlopen("libcuda.so.1")` returns NULL for `libcublasLt.so.13`, `libcusparseLt.so.0` and
  `libcudart.so.13`.

### 3.7 Extra, not SGLang's default: `PYTORCH_NVML_BASED_CUDA_CHECK=1` (what vLLM sets)

```
$ kubectl ... exec sglang-ladder -- bash -c 'PYTORCH_NVML_BASED_CUDA_CHECK=1 python3 /tmp/d-rung3-torch.py'
[maps after import torch] ['/opt/nvml-mock/driver/usr/lib64/libcuda.so.615.23', '/opt/sglang/lib/python3.12/site-packages/nvidia/cu13/lib/libcudart.so.13']
2.13.0+cu130 13.0
[ENGINE] Initialized with 4 devices (4 visible)
avail True
count 4
EXC RuntimeError: Found no NVIDIA driver on your system. Please check that you have an NVIDIA GPU and installed a driver from http://www.nvidia.com/Download/index.aspx
RC=1
```

With torch's NVML-based check, `is_available()` flips to True, through Mokka's NVML. The first allocation fails
exactly as before.

## Rung 4: FAIL (never listening; dies in argument resolution, before any model download)

Script `d-rung4.sh <tag> [env] [args]`. Driver logs `d-rung4-<tag>.log`. Server logs copied out of the pod as
`d-rung4-serve-<tag>.log`. The in-pod path is `/tmp/sglang-serve-<tag>.log`.

Flag check first (`--help`, exit 0):

```
$ kubectl ... exec sglang-ladder -- bash -c 'python3 -m sglang.launch_server --help > /tmp/sglang-help.txt 2>&1; echo help_rc=$?; grep -n -E -- "--model-path|^ *--host|^ *--port|--disable-cuda-graph|--cuda-graph-backend-(decode|prefill)" /tmp/sglang-help.txt | head -20'
help_rc=0
446:  --model-path MODEL_PATH, --model MODEL_PATH
931:  --host HOST           The host of the HTTP server.
932:  --port PORT           The port of the HTTP server.
1340:  --cuda-graph-backend-decode {full,breakable,tc_piecewise,disabled}
1343:  --cuda-graph-backend-prefill {full,breakable,tc_piecewise,disabled}
2448:  --disable-cuda-graph  Deprecated. Use --cuda-graph-
```

### 4.1 The brief's command, FULL exposure (tag `full`)

```
$ kubectl ... exec sglang-ladder -- bash -c 'echo $(date -u +%FT%TZ) launching; nohup timeout 900 python3 -m sglang.launch_server --model-path Qwen/Qwen2.5-0.5B-Instruct --host 0.0.0.0 --port 30000 --disable-cuda-graph > /tmp/sglang-serve-full.log 2>&1 & echo launched_pid=$!'
2026-09-23T07:41:08Z launching
launched_pid=1359
t+15s exited health=000 last: RuntimeError: No accelerator (CUDA, XPU, HPU, NPU, MUSA, MPS) or platform plugin is available.
```

The whole log (34 lines, verbatim apart from an ANSI colour code):

```
/sgl-workspace/sglang/python/sglang/launch_server.py:71: UserWarning: 'python -m sglang.launch_server' is still supported, but 'sglang serve' is the recommended entrypoint.
  Example: sglang serve --model-path <model> [options]
  warnings.warn(
'--disable-cuda-graph' is deprecated and will be removed in a future release. Use '--cuda-graph-backend-{decode,prefill}=disabled' instead.
[2026-09-23 07:41:15] kill_process_tree called: parent_pid=1360, include_parent=False, pid=1360
Traceback (most recent call last):
  File "/sgl-workspace/sglang/python/sglang/srt/utils/common.py", line 945, in get_device
    return current_platform.get_device(device_id)
           ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  File "/sgl-workspace/sglang/python/sglang/srt/platforms/device_mixin.py", line 183, in get_device
    raise NotImplementedError
NotImplementedError

During handling of the above exception, another exception occurred:

Traceback (most recent call last):
  File "<frozen runpy>", line 198, in _run_module_as_main
  File "<frozen runpy>", line 88, in _run_code
  File "/sgl-workspace/sglang/python/sglang/launch_server.py", line 84, in <module>
    run_server(server_args)
  File "/sgl-workspace/sglang/python/sglang/launch_server.py", line 29, in run_server
    server_args.resolve_once()
  File "/sgl-workspace/sglang/python/sglang/srt/server_args.py", line 281, in resolve_once
    run_resolution_pipeline(self)
  File "/sgl-workspace/sglang/python/sglang/srt/arg_groups/pipeline.py", line 145, in run_resolution_pipeline
    run_hook(handle_missing_default_values, server_args)
  File "/sgl-workspace/sglang/python/sglang/srt/arg_groups/resolution_hooks.py", line 198, in run_hook
    step(server_args)
  File "/sgl-workspace/sglang/python/sglang/srt/arg_groups/serving_hook.py", line 595, in handle_missing_default_values
    device=get_device(),
           ^^^^^^^^^^^^
  File "/sgl-workspace/sglang/python/sglang/srt/utils/common.py", line 947, in get_device
    raise RuntimeError(
RuntimeError: No accelerator (CUDA, XPU, HPU, NPU, MUSA, MPS) or platform plugin is available.
```

FIRST fatal error, verbatim: `RuntimeError: No accelerator (CUDA, XPU, HPU, NPU, MUSA, MPS) or platform plugin is available.`

How far it got:

| Stage | Reached? | Evidence |
|---|---|---|
| Platform detected | No. `current_platform` resolved to the base `SRTPlatform`, not `CudaSRTPlatform` | traceback ends in `device_mixin.py:183 raise NotImplementedError`; rung 3.5 `current_platform = 'SRTPlatform'` |
| Config resolved | No. Died at `pipeline.py:145` (`handle_missing_default_values`), before the GPU-memory hook (`:234`) | traceback |
| Model downloaded | No | `/tmp/hf` holds only `.agent_harnesses.json` (12K) after this run |
| Weights loaded / KV cache profiled / listening | No | process exited at t+15s, `/health` 000 |

NVML during this run: none. No `[CONFIG]`/`[ENGINE]` line appears. The mock prints those on every NVML init (every
rung 1-3 process shows them). A second run of the same command under `LD_DEBUG=bindings` (tag `full-ldbind`,
same error) bound zero symbols into `libnvidia-ml`:

```
$ kubectl ... exec sglang-ladder -- bash -c 'bash /tmp/d-ldpid.sh r4bind; echo "--- nvml binding lines, all pids:"; cat /tmp/ld/r4bind.* | grep -c "libnvidia-ml"'
r4bind pid=1519 first_binder=linux-vdso.so.1 nvml=[]           <- timeout
r4bind pid=1520 first_binder=linux-vdso.so.1 nvml=[]           <- python3 -m sglang.launch_server
--- nvml binding lines, all pids:
0
```

(The same helper printed `nvml=[nvmlInit_v2 ]` for the rung-2 positive control, so it can see a hit.)

### 4.2 The brief's command, NVML-ONLY exposure (tag `nvmlonly`)

`LD_LIBRARY_PATH=/opt/nvml-only:<image>`. Same 34-line log and same first fatal error, at the same frames
(`d-rung4-serve-nvmlonly.log`):

```
t+15s exited health=000 last: RuntimeError: No accelerator (CUDA, XPU, HPU, NPU, MUSA, MPS) or platform plugin is available.
```

### 4.3 Extra variant (NOT the standard command; labelled so it is not read as a SGLang default)

The `PYTORCH_NVML_BASED_CUDA_CHECK=1` run is now its own section, Rung 4b, below.

`--device cuda`, FULL, tag `full-devcuda`. With the device given explicitly, argument resolution COMPLETES,
the tokenizer and config files download, the scheduler subprocess starts, and it dies at the first
`set_device` in `ModelRunner`:

```
t+15s alive health=000 last: [2026-09-23 07:43:08] Failed to get device capability: Found no NVIDIA driver on your system. ...
t+30s alive health=000 last: [2026-09-23 07:43:20] server_args={... 'chunked_prefill_size': 4096, 'mem_fraction_static': 0.95, ... 'device': 'cuda', ... 'attention_backend': 'triton', ...}
t+46s exited health=000 last: [2026-09-23 07:43:44] kill_process_tree called: parent_pid=1715, include_parent=True, pid=1715
...
[2026-09-23 07:43:17] Attention backend not specified. Use triton backend by default.
[2026-09-23 07:43:44] Context: self.device='cuda' ps.gpu_id=0 os.environ.get('CUDA_VISIBLE_DEVICES')=None ps.tp_rank=0 ps.tp_size=1
[2026-09-23 07:43:44] Scheduler hit an exception: Traceback (most recent call last):
  File "/sgl-workspace/sglang/python/sglang/srt/managers/scheduler.py", line 5841, in run_scheduler_process
  ...
  File "/sgl-workspace/sglang/python/sglang/srt/model_executor/model_runner.py", line 417, in __init__
    torch.get_device_module(self.device).set_device(ps.gpu_id)
  File "/opt/sglang/lib/python3.12/site-packages/torch/cuda/__init__.py", line 689, in set_device
    torch._C._cuda_setDevice(device)
  File "/opt/sglang/lib/python3.12/site-packages/torch/cuda/__init__.py", line 529, in _lazy_init
    torch._C._cuda_init()
RuntimeError: Found no NVIDIA driver on your system. Please check that you have an NVIDIA GPU and installed a driver from http://www.nvidia.com/Download/index.aspx
[2026-09-23 07:43:44] Received sigquit from a child process. It usually means the child failed.
```

`/tmp/hf` afterwards is 12M: config and tokenizer blobs, no safetensors. None of the resolved values reflect vr200.
SGLang had no GPU memory figure (`get_device_memory_capacity` returns None when `is_cuda()` is False, rung 3.5).
INFERENCE, not traced hook by hook: `chunked_prefill_size=4096`, `mem_fraction_static=0.95` and the triton
attention backend are SGLang's defaults without GPU info, not the >=90 GiB branch of `handle_gpu_memory_settings`. The run again printed no `[NVML]` getter line and no `[NVML-STUB]` line
(three `[CONFIG] Loaded` lines, one per process that initialised NVML).

## Rung 4b: launch_server with `PYTORCH_NVML_BASED_CUDA_CHECK=1` (chief's added experiment): FAIL, one step later

Tags `full-nvmlcheck` (07:42Z), `full-nvmlcheck-ldbind` and `nvmlonly-nvmlcheck` (08:09Z, both under
`LD_DEBUG=bindings`). All three die the same way at t+15s. Server logs: `d-rung4-serve-<tag>.log`.

With the env var (the one vLLM sets for itself), SGLang gets
past `get_device()`, then dies at the next hardware question, which is an import-time SM probe in the DeepGEMM
wrapper, reached while pipeline line 150 imports `expert_pack_hook`:

```
[CONFIG] Loaded YAML config: 4 devices, driver 615.23
[ENGINE] Initialized with 4 devices (4 visible)
...
  File "/sgl-workspace/sglang/python/sglang/srt/arg_groups/pipeline.py", line 150, in run_resolution_pipeline
    from sglang.srt.arg_groups.expert_pack_hook import handle_expert_pack
  ...
  File "/sgl-workspace/sglang/python/sglang/srt/layers/deep_gemm_wrapper/configurer.py", line 39, in <module>
    ENABLE_JIT_DEEPGEMM = _compute_enable_deep_gemm()
  File "/sgl-workspace/sglang/python/sglang/srt/layers/deep_gemm_wrapper/configurer.py", line 18, in _compute_enable_deep_gemm
    sm_version = get_device_sm()
  File "/sgl-workspace/sglang/python/sglang/srt/utils/common.py", line 625, in get_device_sm
    major, minor = torch.cuda.get_device_capability()
  File "/opt/sglang/lib/python3.12/site-packages/torch/cuda/__init__.py", line 720, in get_device_capability
    prop = get_device_properties(device)
  File "/opt/sglang/lib/python3.12/site-packages/torch/cuda/__init__.py", line 737, in get_device_properties
    _lazy_init()  # will define _get_device_properties
  File "/opt/sglang/lib/python3.12/site-packages/torch/cuda/__init__.py", line 529, in _lazy_init
    torch._C._cuda_init()
RuntimeError: Found no NVIDIA driver on your system. Please check that you have an NVIDIA GPU and installed a driver from http://www.nvidia.com/Download/index.aspx
```

Only NVML init and count ran (one `[CONFIG]`/`[ENGINE]` pair, no `[NVML]` getter line). No nvidia-smi memory
query: the memory hook (`:234`) was never reached.

Per-pid NVML bindings for the two traced runs. There is no nvidia-smi child, so the memory query never ran:

```
$ kubectl ... exec sglang-ladder -- bash -c 'bash /tmp/d-ldpid.sh r4bfull r4bnvml'
r4bfull pid=707 ... nvml=[]                                   <- timeout
r4bfull pid=708 ... nvml=[nvmlDeviceGetCount_v2 nvmlInit ]    <- python3 -m sglang.launch_server (FULL)
r4bnvml pid=793 ... nvml=[]
r4bnvml pid=794 ... nvml=[nvmlDeviceGetCount_v2 nvmlInit ]    <- same, NVML-ONLY
```

Why it stops there: `deep_gemm_wrapper/configurer.py:39` runs `ENABLE_JIT_DEEPGEMM = _compute_enable_deep_gemm()`
at import time, and line 18 calls `get_device_sm()`. With the env var, `torch.cuda.is_available()` is True, so
`get_device_sm()` goes on to `torch.cuda.get_device_capability()` and CUDA init fails. Without the env var, the
same call returns 0 silently (rung 3.5), but that path is never reached, because `get_device()` fails first.

### Side by side: launch_server, default vs env var (FULL; NVML-ONLY identical in both columns)

| | Default (rung 4) | `PYTORCH_NVML_BASED_CUDA_CHECK=1` (rung 4b) |
|---|---|---|
| `torch.cuda.is_available()` in the launcher | False (CUDA runtime) | True (Mokka NVML: `nvmlInit`, `nvmlDeviceGetCount_v2` = 4) |
| NVML symbols bound by the launcher | none | `nvmlInit`, `nvmlDeviceGetCount_v2` |
| nvidia-smi invoked | no | no |
| Stops at | `pipeline.py:145` `handle_missing_default_values` -> `get_device()` | `pipeline.py:150` `import expert_pack_hook` -> DeepGEMM `configurer.py:18` `get_device_sm()` |
| First fatal error | `RuntimeError: No accelerator (CUDA, XPU, HPU, NPU, MUSA, MPS) or platform plugin is available.` | `RuntimeError: Found no NVIDIA driver on your system. Please check that you have an NVIDIA GPU and installed a driver from http://www.nvidia.com/Download/index.aspx` |
| Model download / subprocesses / listening | none / none / no | none / none / no |

Model download check after the two 08:09Z runs, in the recreated pod where only rungs 2b and 4b had run:

```
$ kubectl ... exec sglang-ladder -- bash -c 'du -sh /tmp/hf; find /tmp/hf -type f | head'
12K	/tmp/hf
/tmp/hf/.agent_harnesses.json
```

## Rung 5: NOT RUN

Rung 4 never reached "listening" (`/health` was never 200 in any variant), so per LADDER rung 5 does not apply.

## NVML calls observed

Sources: `MOCK_NVML_DEBUG=1` lines (stderr) plus per-pid `LD_DEBUG=bindings` symbol lists (`d-ldpid.sh`).
Note that SGLang's nvidia-smi helpers run `subprocess.run(..., stderr=PIPE)`, which swallows the child's
`MOCK_NVML_DEBUG` output. For those children the per-pid binding list is the only record.

Stubbed / unsupported calls: none, in any log.

```
$ grep -c "NVML-STUB\|FUNCTION_NOT_FOUND\|NOT IMPLEMENTED" d-rung1.log d-rung2.log d-rung3.log d-rung4-*.log d-rung4-serve-*.log
(every file) :0
$ grep -c "C-STUB" d-rung1.log        <- same grep form on a string that is present
8
```

| Caller | NVML symbols bound (LD_DEBUG) | Mock result (MOCK_NVML_DEBUG or python-visible value) |
|---|---|---|
| `sglang.launch_server` (default command, FULL) | none (0 binding lines, pids 1519/1520) | no NVML init at all |
| `sglang.launch_server` + `PYTORCH_NVML_BASED_CUDA_CHECK=1` | not traced | one `[ENGINE] Initialized with 4 devices (4 visible)`, no getter lines |
| `sglang.launch_server --device cuda` | not traced | three `[CONFIG] Loaded YAML config: 4 devices, driver 615.23`, no getter lines |
| `python3 -m sglang.check_env` python process | none | n/a |
| `nvidia-smi topo -m` child of check_env | `nvmlInitWithFlags nvmlInternalGetExportTable nvmlDeviceGetCount_v2 nvmlDeviceGetHandleByIndex_v2 nvmlDeviceGetArchitecture nvmlDeviceGetBrand nvmlDeviceGetPciInfo_v3 nvmlDeviceGetFieldValues nvmlDeviceGetCpuAffinity nvmlDeviceGetMemoryAffinity nvmlDeviceGetNumaNodeId nvmlDeviceGetNvLinkRemotePciInfo_v2 nvmlShutdown` | NV18 between every GPU pair, CPU 0-63 / 64-127, NUMA 0 / 1 (rung 2.1 matrix) |
| `get_nvgpu_memory_capacity` -> nvidia-smi child | `nvmlInitWithFlags nvmlInternalGetExportTable nvmlDeviceGetCount_v2 nvmlDeviceGetHandleByIndex_v2 nvmlDeviceGetMemoryInfo_v2 nvmlShutdown` | `294912` MiB x4 (rung 1: `nvmlDeviceGetMemoryInfo_v2 -> total=309237645312 reserved=1339031552 used=0`) |
| `get_device_sm_nvidia_smi` -> nvidia-smi child | `... nvmlDeviceGetCudaComputeCapability ...` | `10.7` |
| `get_nvidia_driver_version_str` -> nvidia-smi child | `... nvmlSystemGetDriverVersion ...` | `615.23` |
| `numa_utils._query_numa_node_for_gpu` (pynvml) | `nvmlInitWithFlags nvmlDeviceGetHandleByIndex_v2 nvmlDeviceGetMemoryAffinity nvmlShutdown` | `nvmlDeviceGetHandleByIndex(i) -> ret=0`, `nvmlDeviceGetMemoryAffinity -> [1]` (GPU 0,1), `[2]` (GPU 2,3) |
| `cuda_vmm_utils.is_gpu_fabric_ready` / `_gpu_fabric_clique` (pynvml) | `nvmlInitWithFlags nvmlDeviceGetHandleByIndex_v2 nvmlDeviceGetGpuFabricInfoV nvmlShutdown` | `nvmlDeviceGetGpuFabricInfoV -> clique=32766 state=3 healthMask=0x1aa healthSummary=1` |
| `custom_all_reduce_utils.is_full_nvlink` (DIAGNOSTIC, harness-bound pynvml) | `nvmlInitWithFlags nvmlDeviceGetHandleByIndex_v2 nvmlDeviceGetP2PStatus nvmlShutdown` | `nvmlDeviceGetP2PStatus(i,j) -> OK (nvlink)` for all 6 pairs |
| torch `torch.cuda.device_count()` (ctypes, torch's own) | `nvmlInit nvmlDeviceGetCount_v2` | `[ENGINE] Initialized with 4 devices (4 visible)`, count 4 |
| Rung 2b/4b: SGLang process with `PYTORCH_NVML_BASED_CUDA_CHECK=1` (torch's NVML-based availability) | `nvmlInit nvmlDeviceGetCount_v2` | count 4, so `is_available()` True |
| Rung 2b: `is_full_nvlink` UNMODIFIED with the env var | `nvmlInit nvmlInitWithFlags nvmlDeviceGetCount_v2 nvmlDeviceGetHandleByIndex_v2 nvmlDeviceGetP2PStatus nvmlShutdown` | 6x `OK (nvlink)`, returns True |

Every NVML call any process made returned success. The first failure on every path is in the CUDA driver API
(section 3.2), never in NVML.

## Where the line is

In this pod Mokka's NVML and nvidia-smi answer every NVML query with vr200 data: 4 x "NVIDIA Graphics Device",
294912 MiB, CC 10.7, driver 615.23, NV18 all-to-all, NUMA 0/1, fabric clique 32766 COMPLETED, P2P OK. SGLang's
nvidia-smi and pynvml helpers read those values correctly when called directly. But SGLang v0.5.20 decides
whether there is a GPU with `torch.cuda.is_available()`, which is the CUDA runtime's device count, and never
sets `PYTORCH_NVML_BASED_CUDA_CHECK`. torch's cudart 13 needs the driver API. Mokka's `libcuda.so.1`
(dlopened by cuBLASLt at `import torch` in the FULL exposure) resolves only `cuInit`: `cuDriverGetVersion`,
`cuGetProcAddress_v2`/`cuGetProcAddress` and `cuDeviceGetCount` are looked up and not found. The NVML-ONLY
exposure has no libcuda at all. Either way `is_available()` is False, every SGLang capability gate
(`is_cuda`, `is_sm100`, `is_blackwell`, `get_device_sm`, platform selection) reports "no CUDA", and
`launch_server` stops in argument resolution at `get_device()` with
`RuntimeError: No accelerator (CUDA, XPU, HPU, NPU, MUSA, MPS) or platform plugin is available.`
That happens before any NVML call, model download or subprocess. The first thing Mokka could not provide is a
CUDA driver API usable by the real CUDA 13 runtime (`cuGetProcAddress` and the entry points behind it). NVML
is not the gap. The same wall shows up as "Found no NVIDIA driver on your system" as soon as anything forces
the question: the LADDER allocation, the `PYTORCH_NVML_BASED_CUDA_CHECK=1` variant, and the `--device cuda`
variant's scheduler `set_device`.

With `PYTORCH_NVML_BASED_CUDA_CHECK=1` (rungs 2b/4b), current Mokka is enough for SGLang's own code to see
4 CUDA GPUs, 294912 MiB each, NVLink all-to-all and the CUDA platform. It is not enough for the compute
capability, the device name or any SM/Blackwell gate, and the server still stops during argument resolution
(`pipeline.py:150`, DeepGEMM's import-time `get_device_sm()`), with "Found no NVIDIA driver on your system".
Precise "before" picture of that failure (rung 3.6): in FULL, torch's `libcudart.so.13` first asks Mokka's
`libcuda.so.1` for `cuGetProcAddress_v2` (NULL). Of its 440 distinct driver names, only `cuInit` resolves.
cuBLASLt and cuSPARSELt each resolve only `cuInit` of 32. In NVML-ONLY, all three `dlopen("libcuda.so.1")`
calls return NULL.

## Chief's predictions (a), (b) and task B's 2b/4b prediction: CONFIRMED / REFUTED

| Claim | Verdict | Evidence |
|---|---|---|
| (a1) SGLang never sets `PYTORCH_NVML_BASED_CUDA_CHECK` (0 hits under python/; 5 in vLLM) | CONFIRMED | `grep -rn PYTORCH_NVML_BASED_CUDA_CHECK .../sglang-v0.5.20/python` -> rc=1, no output. The same string in vLLM: `grep -rc` gives `docker/Dockerfile.rocm:2`, `docker/Dockerfile.rock:2`, `vllm/env_override.py:1` = 5 hits |
| (a2) so `torch.cuda.is_available()` goes through the CUDA runtime and returns False on the mock | CONFIRMED | rung 3.2/3.3 `avail False` in both exposures; rung 3.6: cudart's `cuGetProcAddress_v2` etc. return NULL (FULL) or `dlopen("libcuda.so.1")` returns NULL (NVML-ONLY) |
| (a3) which gates off every probe: zero NVML calls and zero nvidia-smi calls | CONFIRMED on the serve path; qualified for check_env | Serve (rung 4.1): 0 binding lines into libnvidia-ml, no `[CONFIG]` line, only 2 pids (timeout, python), so no nvidia-smi child. Qualification: `python3 -m sglang.check_env` still runs `nvidia-smi topo -m` (pid 160 bound 13 NVML symbols, rung 2.1), because its topology section is not gated on `is_available()` |
| (b) dies in the launcher during arg resolution with "RuntimeError: No accelerator (CUDA, XPU, HPU, NPU, MUSA, MPS) or platform plugin is available." (`common.py:948` via `serving_hook.py:595`) | CONFIRMED | rung 4.1 traceback: `serving_hook.py, line 595` -> `common.py, line 947, in get_device: raise RuntimeError(` (the message literal is on line 948), launcher only, t+15s; identical under NVML-ONLY |
| B 5.2.4 part 1: with the env var SGLang gets further | CONFIRMED | discovery (2b): `is_available True`, `get_device() = 'cuda'`, `get_device_count() = 4`, `CudaSRTPlatform`; serve (4b): passes `pipeline.py:145` |
| B 5.2.4 part 2: nvidia-smi `memory.total` = 294912 | CONFIRMED for SGLang's own helper, REFUTED on the serve path | 2b: `get_device_memory_capacity('cuda') = 294912.0` (nvidia-smi child bound `nvmlDeviceGetMemoryInfo_v2`). 4b: the serve process dies at `pipeline.py:150`, before the memory hook at `:234`; no nvidia-smi child in the per-pid list |
| B 5.2.4 part 3: then "Found no NVIDIA driver on your system" at the first real CUDA use | CONFIRMED (text); location earlier than B's "no later than :259" bound | 4b: `get_device_sm()` inside the DeepGEMM wrapper's import-time `_compute_enable_deep_gemm()` (`configurer.py:18,39`), reached from `pipeline.py:150` |
| "One env var separates 'SGLang sees nothing' from 'SGLang sees 4x VR200'" | PARTLY. It separates "no accelerator" from "4 CUDA GPUs, 294912 MiB each, NVLink all-to-all, CUDA platform". It does NOT give SGLang the VR200 identity | With the env var, SGLang's name, compute capability and every SM/Blackwell gate go through `torch.cuda.get_device_properties` and raise (2b table). SGLang never reads "NVIDIA Graphics Device" or 10.7 through its own code, and the server still dies before any model work (4b) |

## Prediction vs measurement

Against task B's PREDICTION 5.2 (`task-B-surface-report.md`, read at ~06:50Z) and its SGLang table 4.3:

| Task B prediction | Measured | Verdict |
|---|---|---|
| 5.2.1 Zero NVML calls and zero nvidia-smi invocations by SGLang before it dies; no `[NVML]` lines | 0 binding lines into libnvidia-ml in the serve process; no `[CONFIG]`/`[ENGINE]`/`[NVML]` line in the serve log | Confirmed |
| 5.2.2 `torch.cuda.is_available()` silently False (no warning if cudart reports insufficient driver) | False. The 34-line serve log has no `CUDA initialization` warning. Extra detail: Mokka's libcuda is dlopened by cuBLASLt at `import torch` and resolves only `cuInit` | Confirmed |
| 5.2.3 First fatal: `RuntimeError: No accelerator (CUDA, XPU, HPU, NPU, MUSA, MPS) or platform plugin is available.` via `serving_hook.py:595`, launcher process, no scheduler | Exactly that text and frames (`pipeline.py:145` -> `serving_hook.py:595` -> `common.py:947`), launcher only | Confirmed |
| 5.2.4 With `PYTORCH_NVML_BASED_CUDA_CHECK=1`: runs the nvidia-smi memory query (`pipeline.py:234`), then dies at the first `get_device_capability`, no later than the attention-backend hook (`:259`); "an earlier hook ... may get there first; not traced" | Died EARLIER, at `pipeline.py:150` (`import expert_pack_hook` -> DeepGEMM `configurer.py:18` `get_device_sm()` at import time). The nvidia-smi memory query never ran. Error text as predicted | Direction right, location wrong (earlier) |
| 5.2.4 With `--device cuda`: failure moves to the scheduler's `set_device` (`model_runner.py:417`) | Exactly `model_runner.py:417` `set_device` -> "Found no NVIDIA driver on your system" | Confirmed |
| 4.3 `get_nvgpu_memory_capacity` INFERENCE `294912`; `get_device_sm_nvidia_smi` INFERENCE `10.7`; driver `615.23` | `294912.0`, `(10, 7)`, `'615.23'` | Confirmed |
| 4.3 fabric clique 32766, cluster `...0001` | `(b'\x00...\x01', 32766)`, state 3 | Confirmed |
| 4.3 NUMA node 0 or 1 | NVML answers 0/1 correctly, but SGLang's helper returns `[]` because the pod has no `/sys/devices/system/node` | Not predicted (kind/linuxkit sysfs, not Mokka) |
| 2.4 caveat: engine may see A100 defaults under CDI | Not applicable to this pod (manual recipe sets `MOCK_NVML_CONFIG`); `[CONFIG] Loaded YAML config: 4 devices, driver 615.23` | n/a |
| 6.5 risk: two Go runtimes in one process | Both Mokka libcuda and libnvidia-ml mapped in the same python process in every rung-2/3 FULL run; no crash or hang | Risk did not materialise here |
| 6.6 `libcudart.so.12 -> libcuda.so.1` should not shadow a CUDA 13 torch | torch `2.13.0+cu130` needs `libcudart.so.13` via DT_RPATH (searched before `LD_LIBRARY_PATH`); the loader never looked at the mock's `libcudart.so.12` | Confirmed |

## Cleanup

```
$ kubectl --context kind-mokka-vr200-llm -n spike-sglang delete pod sglang-ladder --wait=true --timeout=120s
pod "sglang-ladder" deleted from spike-sglang namespace
delete_rc=0
$ kubectl --context kind-mokka-vr200-llm -n spike-sglang get pods
No resources found in spike-sglang namespace.
```

The pod was recreated at ~08:05Z for the chief's follow-ups (rungs 2b, 4b, 3.6) and deleted again at 08:13Z:

```
$ kubectl --context kind-mokka-vr200-llm -n spike-sglang delete pod sglang-ladder --wait=true --timeout=120s
pod "sglang-ladder" deleted from spike-sglang namespace
delete_rc=0
$ kubectl --context kind-mokka-vr200-llm -n spike-sglang get pods
No resources found in spike-sglang namespace.
```

I left the namespace, node labels, the nvml-mock release, the device plugin and the pulled image as I found them.
No tracked repo files were edited, and nothing was committed, pushed or posted. The scratch scripts and logs
stay under `/tmp/vr200-llm-spike-58fc971e/d-*` as evidence.
