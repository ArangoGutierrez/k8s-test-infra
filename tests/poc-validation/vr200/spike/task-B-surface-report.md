# Task B report: vLLM / SGLang hardware-discovery surface vs Mokka nvml-mock (vr200)

Status: DONE_WITH_CONCERNS (concerns in section 6; the headline ones are 6.2, a possible A100 fallback under CDI
injection, and 6.4, where libcudart's behaviour against the mock is inferred rather than measured)
Worker: Task B (static analysis only, no cluster, no docker)
Date: 2026-09-23

Headline (details in section 5): NVML is not the gap for either engine. Every NVML symbol on either serve path is
exported and returns vr200 data when the profile loads. Both engines fail on the CUDA driver API, because Mokka's
`libcuda.so.1` has no `cuGetProcAddress`. vLLM gets through discovery using NVML and dies at the worker's first
`set_device` with `Found no NVIDIA driver on your system...`. SGLang checks availability through the CUDA runtime,
so it never calls NVML, and it dies earlier, during argument resolution, with
`No accelerator (CUDA, XPU, HPU, NPU, MUSA, MPS) or platform plugin is available.`

Path shorthands used in every citation below:

- `M:` = Mokka worktree `<repo>/.worktrees/spike-vr200-llm` (PR #872 head 8058e1c9)
- `V:` = `/tmp/vr200-llm-spike-58fc971e/taskB/vllm-v0.30.0`
- `S:` = `/tmp/vr200-llm-spike-58fc971e/taskB/sglang-v0.5.20`
- `T:` = `/tmp/vr200-llm-spike-58fc971e/taskB/torch-2.13.0/` (single files fetched from pytorch@v2.13.0 and triton@5d6048aa, file name = repo path with `/` replaced by `_`)
- `P:` = `V:vllm/third_party/pynvml.py` (vLLM's vendored nvidia-ml-py, header says `version 12.570.86`)

## 1. Source provenance

```
$ git clone --depth 1 --branch v0.30.0 https://github.com/vllm-project/vllm vllm-v0.30.0   -> rc=0
$ git clone --depth 1 --branch v0.5.20 https://github.com/sgl-project/sglang sglang-v0.5.20 -> rc=0
$ git -C vllm-v0.30.0 describe --tags --exact-match
v0.30.0
ced6857afa0ea7b2e3f0846a62e1394e90f15607 Mon Sep 21 15:32:49 2026 -0700 [CI][Build] Harden triton-cpu sleef submodule fetch in CPU image build (#57871)
$ git -C sglang-v0.5.20 describe --tags --exact-match
v0.5.20
94602c9c2b7cbdb8efd5c52802dac6a1c180089e Fri Sep 18 01:00:43 2026 -0700 [Cherry-pick to release/v0.5.20] [gRPC] Stream engine state changes (#39915) (#40137)
$ git -C <mokka worktree> log -1 --format='%H %s'
8058e1c9fe1ed278357b820094fe2b22170804c1 fix(vr200): cover the profile in the utilization guard and correct its memory line
```

Both tag names exist as given; no substitution was needed.

torch: `V:requirements/cuda.txt:7` pins `torch==2.13.0`. `git ls-remote --tags https://github.com/pytorch/pytorch 'v2.13.0*'` returned `cf30153c... refs/tags/v2.13.0`. The files under `T:` were fetched with `curl -fsSL https://raw.githubusercontent.com/pytorch/pytorch/v2.13.0/<path>` (all rc=0). torch v2.13.0 pins triton 3.7.1, commit `5d6048aa0a324e090ada215b609ea76620133845` (`.ci/docker/triton_version.txt`, `.ci/docker/ci_commit_pins/triton.txt`); `T:triton_nvidia_driver.py` is `third_party/nvidia/backend/driver.py` at that commit.

## 2. Mokka surface (what an engine pod can actually reach)

### 2.1 NVML exports

- 421 `//export` lines: 168 hand-written + 253 in `M:pkg/gpu/mocknvml/bridge/stubs_generated.go`
  (`grep -n '^//export' ... | wc -l`).
- 14 unversioned names are linker aliases, not exports: `M:pkg/gpu/mocknvml/Makefile:65-79`
  (`-Wl,--defsym,nvmlDeviceGetPciInfo=nvmlDeviceGetPciInfo_v3` etc.). The production image builds through that
  Makefile: `M:deployments/nvml-mock/Dockerfile` runs `cd pkg/gpu/mocknvml && make clean && make`.
- Some getters are gated by `bridgeVersionCheck` (`M:pkg/gpu/mocknvml/bridge/helpers.go:158`). It returns
  FUNCTION_NOT_FOUND only when the profile's driver is older than the registry's `Added` version
  (`M:pkg/gpu/mocknvml/engine/version.go:134`). vr200 is driver 615.23 (`vr200.yaml:23`), newer than every
  entry this report touches (for example `nvmlDeviceGetMemoryInfo_v2 Added 510.0`, `version.go:47`).

Every symbol either engine or torch resolves on the serve path, checked against the export list (one grep that
can print a hit for each name):

```
$ for s in ...; do grep -E ":${s}\$" exports_all.txt | head -1 || echo NOT_EXPORTED; done
nvmlInit                                      init.go:65:nvmlInit
nvmlInit_v2                                   init.go:36:nvmlInit_v2
nvmlInitWithFlags                             init.go:42:nvmlInitWithFlags
nvmlShutdown                                  init.go:54:nvmlShutdown
nvmlErrorString                               helpers.go:167:nvmlErrorString
nvmlDeviceGetCount_v2                         device.go:129:nvmlDeviceGetCount_v2
nvmlDeviceGetHandleByIndex_v2                 device.go:155:nvmlDeviceGetHandleByIndex_v2
nvmlDeviceGetHandleByUUID                     device.go:182:nvmlDeviceGetHandleByUUID
nvmlDeviceGetIndex                            device.go:239:nvmlDeviceGetIndex
nvmlDeviceGetCudaComputeCapability            device.go:726:nvmlDeviceGetCudaComputeCapability
nvmlDeviceGetName                             device.go:217:nvmlDeviceGetName
nvmlDeviceGetUUID                             device.go:228:nvmlDeviceGetUUID
nvmlDeviceGetMemoryInfo                       device.go:380:nvmlDeviceGetMemoryInfo
nvmlDeviceGetMemoryInfo_v2                    device.go:686:nvmlDeviceGetMemoryInfo_v2
nvmlDeviceGetP2PStatus                        nvlink.go:57:nvmlDeviceGetP2PStatus
nvmlDeviceGetNumaNodeId                       affinity.go:104:nvmlDeviceGetNumaNodeId
nvmlDeviceGetCpuAffinity                      affinity.go:56:nvmlDeviceGetCpuAffinity
nvmlDeviceGetCpuAffinityWithinScope           affinity.go:72:nvmlDeviceGetCpuAffinityWithinScope
nvmlDeviceGetPciInfo                          NOT_EXPORTED   <- provided by --defsym, Makefile:66
nvmlDeviceGetPciInfo_v3                       device.go:299:nvmlDeviceGetPciInfo_v3
nvmlSystemGetDriverVersion                    system.go:39:nvmlSystemGetDriverVersion
nvmlSystemGetCudaDriverVersion                system.go:86:nvmlSystemGetCudaDriverVersion
nvmlSystemGetCudaDriverVersion_v2             system.go:91:nvmlSystemGetCudaDriverVersion_v2
nvmlDeviceGetTopologyCommonAncestor           device.go:401:nvmlDeviceGetTopologyCommonAncestor
nvmlDeviceGetNvLinkState                      device.go:435:nvmlDeviceGetNvLinkState
nvmlDeviceGetComputeRunningProcesses_v3       device.go:762:nvmlDeviceGetComputeRunningProcesses_v3
nvmlDeviceGetMinorNumber                      device.go:280:nvmlDeviceGetMinorNumber
nvmlDeviceGetHandleByPciBusId_v2              device.go:195:nvmlDeviceGetHandleByPciBusId_v2
nvmlSystemGetNVMLVersion                      system.go:51:nvmlSystemGetNVMLVersion
```

(paths relative to `M:pkg/gpu/mocknvml/bridge/`). Result: no NVML symbol either engine needs on its serve path
is missing. NVML is not where these engines break.

### 2.2 vr200 values the engine serves (only when the profile YAML is loaded, see 2.4)

| Getter | Engine implementation | vr200 value (source) |
|---|---|---|
| device count | `M:pkg/gpu/mocknvml/engine/engine.go:322`, filtered by `/dev/nvidia<minor>` presence at `engine.go:698-726` | 4 devices (`vr200.yaml:440-479`); fewer if only some `/dev/nvidia<minor>` nodes exist in the pod |
| name | `engine/device.go:469` | `"NVIDIA Graphics Device"` (`vr200.yaml:48`) |
| compute capability | `engine/device.go:1912` (set at `device.go:175-176`) | `(10, 7)` (`vr200.yaml:66-68`) |
| memory (v1) | `engine/device.go:512` | total 309237645312, free 307898613760, used 0 (`vr200.yaml:118,120,121`) |
| memory (v2) | `engine/device.go:522` | as v1 plus reserved 1339031552 (`vr200.yaml:119`) |
| UUID | `engine/device.go:458` | `GPU-307f0000-0000-0000-0000-00000000000{0..3}` (`vr200.yaml:442,452,462,472`) |
| PCI bus id | `engine/device.go:543` | `0002:81:00.0`, `0002:C1:00.0`, `000A:81:00.0`, `000A:E1:00.0` (`vr200.yaml:445,455,465,475`) |
| minor number | `engine/device.go:478` | 0, 3, 1, 2 for indices 0..3 (`vr200.yaml:446,456,466,476`): not identity |
| P2P status | `engine/device.go:1599` | OK when the fabric reports NVLinkCount>0 (vr200 declares an 18-link NVLink 6 fabric, `vr200.yaml:492-511`), else NOT_SUPPORTED |
| NUMA node | `engine/device.go:1767` | 0 for GPUs 0,1; 1 for GPUs 2,3 (`vr200.yaml:542-553`); NOT_SUPPORTED without pcie_topology |
| CPU affinity | `engine/device.go:1782` | mask derived from pcie_topology; NOT_SUPPORTED without it |

### 2.3 CUDA: the mock libcuda and how (whether) it reaches a pod

- The CUDA mock is `M:pkg/gpu/mockcuda` (the CONTEXT file says `shims/libcuda`; that path does not exist:
  `ls M:shims` lists only `libibmock libmockfs nvidia-imex-shim`). 15 exports, all in
  `M:pkg/gpu/mockcuda/bridge/cuda.go:35-187`: `cuInit` plus 14 `cuda*` runtime names. There is no
  `cuGetProcAddress`, `cuGetProcAddress_v2`, `cuDriverGetVersion`, `cuDeviceGet*`, `cuCtx*` or `cuMem*`
  (`grep -rn '^//export' M:pkg/gpu/mockcuda` prints exactly the 15).
- `M:docs/cuda-mock.md` already records a MEASUREMENT by the Mokka authors: a static-cudart sample resolves the
  driver through `dlopen("libcuda.so.1")` + `cuGetProcAddress`, never enters the mock, and prints "CUDA driver
  version is insufficient" identically with and without the mock mounted.
- Delivery into a workload pod has two modes, and they differ:
  - CDI (`nvidia.com/gpu` via the device plugin and container toolkit), `M:internal/agent/cdi/spec.go:70-119`:
    mounts ONLY `/usr/lib64/libnvidia-ml.so.1`, `/usr/bin/nvidia-smi`, and the config dir at `/etc/nvml-mock`.
    No `libcuda.so.1`. The spec's env (`MOCK_NVML_CONFIG=/etc/nvml-mock/config.yaml`) is documented as dropped by
    the toolkit (`spec.go:107-112`, issue #747; `M:docs/helm-chart.md:394-398`).
  - NRI (`nri.enabled`), `M:internal/nri/inject/env.go:17-20`: prepends `<overlay>/driver/usr/lib64` to
    `LD_LIBRARY_PATH`, sets `MOCK_NVML_CONFIG`, adds `LD_PRELOAD` shims. That directory holds
    `libnvidia-ml.so.1`, `libcuda.so.1`, and `libcudart.so.12 -> libcuda.so.1`
    (`M:internal/agent/gpudriver/stage.go:143-158`). So under NRI the mock libcuda IS first on the search path.

### 2.4 Config discovery caveat (affects whether the pod sees vr200 or A100 data)

`M:pkg/gpu/mocknvml/engine/config.go:71-114`: the mock reads `MOCK_NVML_CONFIG`, else derives
`<lib dir>/../../config/config.yaml` from `/proc/self/maps` (`config.go:176-221`), else falls back to
`DefaultConfig()` = 8 devices, driver 550.163.01 (`config.go:57-61`), built by `createDefaultDevices`
(`M:pkg/gpu/mocknvml/engine/engine.go:222-251`: UUIDs `GPU-4d4f434b-0000-0000-0000-00000000000N`, minor = index)
on go-nvml's `dgxa100.New()` = 8 x `gpus.A100_SXM4_40GB` (`go-nvml@v0.13.3-1/pkg/nvml/mock/dgxa100/dgxa100.go:56`):
name `"Mock NVIDIA A100-SXM4-40GB"`, 40960 MiB, CC 8.0 (`go-nvml@v0.13.3-1/pkg/nvml/mock/gpus/a100.go:45-54`).

INFERENCE: under CDI mode the library is at `/usr/lib64/libnvidia-ml.so.1`, so discovery computes
`/config/config.yaml` (absent), and the env var is dropped (#747). Unless the pod sets `MOCK_NVML_CONFIG`
itself, an engine under CDI mode sees A100 defaults, not vr200. Under NRI mode `MOCK_NVML_CONFIG` is injected
and the pod sees vr200. The live ladder should check this first (`nvidia-smi -L` inside the engine pod).
Every "vr200 value" in the tables below assumes the profile was loaded.

### 2.5 nvidia-smi

The image ships the real `nvidia-smi` from `nvidia-utils-580=580.65.06` with RPATH `$ORIGIN/../lib64`
(`M:deployments/nvml-mock/Dockerfile`, the `apt-get download nvidia-utils-580` and `patchelf` lines). It runs
unmodified against the mock NVML, so every query flag it supports goes through the NVML exports above. Whether
a given `--query-gpu` field works depends on the NVML getters behind it, not on the binary.

## 3. vLLM v0.30.0

### 3.1 Serve path (the order things happen)

1. `import vllm` runs `V:vllm/env_override.py:164`, which sets `PYTORCH_NVML_BASED_CUDA_CHECK=1`. From then on
   `torch.cuda.is_available()` = `device_count() > 0` via NVML (`T:torch_cuda___init__.py:179-183`), not
   `cudaGetDeviceCount`. This is the single most important fact for the prediction: in vLLM processes torch's
   availability check is answered by Mokka's NVML and returns True.
2. Platform detection, `V:vllm/platforms/__init__.py:59-107` (`cuda_platform_plugin`): nvmlInit, then
   nvmlDeviceGetCount twice (`:74`, `:77`), then nvmlShutdown. `is_cuda` also requires the vLLM version not to
   contain "cpu" (`:75`). Other plugins: `xpu_platform_plugin` imports torch (`:149`), `cpu_platform_plugin`
   returns None on the CUDA image (`:186-205`).
3. Import of `V:vllm/platforms/cuda.py`: `:1065-1075` nvmlInit/nvmlShutdown picks `NvmlCudaPlatform`; `:1079`
   `log_warnings()` enumerates all devices by name (`:1013-1027`).
4. Config construction in the API server process: dtype via `supported_dtypes` -> `has_device_capability(80)`
   -> NVML compute capability (`cuda.py:254-264`, `:793-800`); batch defaults via
   `get_device_total_memory()` + `get_device_name()` (`V:vllm/engine/arg_utils.py:2719-2759`); the world-size
   check `device_count()` (`V:vllm/config/parallel.py:978-989`) -> `torch.cuda._device_count_nvml()`
   (`cuda.py:57-79`).
5. EngineCore process, `UniProcExecutor._init_executor` (`V:vllm/v1/executor/uniproc_executor.py:52-75`) ->
   `Worker.init_device` (`V:vllm/v1/worker/gpu_worker.py:360-458`):
   - `:415` `torch.accelerator.device_count()` -> `torch.cuda.device_count()` (`T:torch_accelerator___init__.py:54-70`
     delegates to `mod.device_count()`), NVML-backed before CUDA init (`T:torch_cuda___init__.py:1150-1176`; with
     `CUDA_VISIBLE_DEVICES` unset, `_parse_visible_devices` returns `range(64)`, `:887-888`, so the NVML count wins).
   - `:421` visible-id mapping (NVML only if `CUDA_VISIBLE_DEVICES` holds UUIDs).
   - `:424` `torch.accelerator.set_device_index(...)`: the binding calls
     `torch::utils::maybe_initialize_device` before `setDeviceIndex` (`T:torch_csrc_DeviceAccelerator.cpp:21-29`),
     i.e. `torch.cuda._lazy_init()` -> `torch._C._cuda_init()` (`T:torch_cuda___init__.py:501-529`) ->
     `CUDAHooks::init` -> `device_count_ensure_non_zero()` (`T:aten_src_ATen_cuda_detail_CUDAHooks.cpp:86-89`,
     `T:c10_cuda_CUDAFunctions.cpp:126-135`). First real CUDA driver contact.
   - Everything after `:424` (dtype check `:426`, NCCL init `:432`, `MemorySnapshot` `:451`, model runner,
     attention backend choice, weight load) is not reached if `:424` raises.

### 3.2 Table

| Call (Python site file:line) | C symbol | On serve path? | Mokka | vr200 value / return (file:line) |
|---|---|---|---|---|
| `pynvml.nvmlInit()` `V:vllm/platforms/__init__.py:66`, `cuda.py:200`, `cuda.py:1068` | `nvmlInitWithFlags` (`P:2380`, `nvmlInit` delegates at `P:2391`) | yes, API server + EngineCore, many times | implemented | SUCCESS; flags ignored (`M:.../bridge/init.go:42-52`), refcounted (`engine/engine.go:70-113`) |
| `pynvml.nvmlShutdown()` `__init__.py:86`, `cuda.py:204`, `:1075` | `nvmlShutdown` (`P:2433`) | yes | implemented | SUCCESS; decrements refcount (`engine/engine.go:300-319`) |
| `pynvml.nvmlDeviceGetCount()` `__init__.py:74,77`, `cuda.py:1015` | `nvmlDeviceGetCount_v2` (`P:2599`) | yes | implemented | 4 (`vr200.yaml:440-479`; `engine.go:322`); /dev-node filtering `engine.go:698-726` |
| `pynvml.nvmlDeviceGetHandleByIndex()` `cuda.py:796,828,835,844,866,874,1002` | `nvmlDeviceGetHandleByIndex_v2` (`P:2607`) | yes | implemented | SUCCESS for 0..3 (`bridge/device.go:155`, `engine.go:336`) |
| `pynvml.nvmlDeviceGetName()` `cuda.py:867` (via `log_warnings` `:1017`, `get_device_name` `:820`) | `nvmlDeviceGetName` (`P:2642`) | yes: `log_warnings` at import, `arg_utils.py:2721` | implemented | `"NVIDIA Graphics Device"` x4 (`vr200.yaml:48`; `engine/device.go:469`). All names equal, so no "different devices" warning (`cuda.py:1018-1027`) |
| `pynvml.nvmlDeviceGetCudaComputeCapability()` `cuda.py:797` | `nvmlDeviceGetCudaComputeCapability` (`P:3221`) | yes: dtype resolution (`cuda.py:256`), attention backend (`cuda.py:456`) | implemented | `(10, 7)` (`vr200.yaml:66-68`; `engine/device.go:1912`) |
| `pynvml.nvmlDeviceGetMemoryInfo(h).total` `cuda.py:836` | `nvmlDeviceGetMemoryInfo` (v1, no version arg: `P:3192-3196`) | yes: `arg_utils.py:2720`; `V:vllm/v1/worker/startup_plan.py:66` | implemented | total 309237645312 (`vr200.yaml:118`; `engine/device.go:512`). >= 160 GiB, so `arg_utils.py:2730-2739` picks max_num_batched_tokens 16384 and max_num_seqs 1024 for the API server |
| `pynvml.nvmlDeviceGetUUID()` `cuda.py:829` | `nvmlDeviceGetUUID` (`P:2792`) | no (`V:vllm/model_executor/model_loader/weight_cache/protocol.py:112` only) | implemented | `GPU-307f0000-...-000000000000` (`vr200.yaml:442`) |
| `pynvml.nvmlDeviceGetHandleByUUID()` + `nvmlDeviceGetIndex()` `cuda.py:787-788` | `nvmlDeviceGetHandleByUUID` (`P:2625`), `nvmlDeviceGetIndex` (`P:3834`) | only if `CUDA_VISIBLE_DEVICES` holds UUIDs (`V:vllm/platforms/interface.py:304-310,349-360`) | implemented | index of the matching UUID (`engine.go:355`, `engine/device.go:435`) |
| `pynvml.nvmlDeviceGetP2PStatus(..., NVML_P2P_CAPS_INDEX_NVLINK)` `cuda.py:849-853` | `nvmlDeviceGetP2PStatus` (`P:4640`) | no at TP=1: callers are custom/quick all-reduce (`V:vllm/distributed/device_communicators/custom_all_reduce.py:235`, `quick_all_reduce.py:158`) | implemented | P2P_STATUS_OK for distinct NVLink-connected pairs (`engine/device.go:1599-1615`) |
| `pynvml.nvmlDeviceGetNumaNodeId()` `cuda.py:877`; `nvmlDeviceGetCpuAffinity()` `cuda.py:927` | `nvmlDeviceGetNumaNodeId` (`P:2776`), `nvmlDeviceGetCpuAffinity` (`P:2758`) | no: only via `get_all_device_numa_nodes` (`V:vllm/utils/numa_utils.py:109`), gated on `numa_bind`, default False (`V:vllm/config/parallel.py:293`) | implemented | NUMA 0/1 (`vr200.yaml:542-553`; `engine/device.go:1767,1782`) |
| `pynvml.nvmlDeviceGetPciInfo()` `cuda.py:1003` | `nvmlDeviceGetPciInfo_v3` (`P:2873` delegates to `P:2868`) | no: only when `VLLM_GPU_NIC_PCIE_MAPPING` is set (`V:vllm/v1/executor/vllm_net_devices.py:239-240,150`) | implemented | `0002:81:00.0` etc. (`vr200.yaml:445`; `engine/device.go:543`) |
| NVMLError text, any failing call | `nvmlErrorString` (`P:2448`) | on error only | implemented | `M:.../bridge/helpers.go:167` |
| torch `_raw_device_count_nvml` via `torch.cuda.device_count()` (vLLM `cuda.py:77`, `gpu_worker.py:415`, `is_available` after env_override) | ctypes `nvmlInit`, `nvmlDeviceGetCount_v2` (`T:torch_cuda___init__.py:950-956`) | yes | implemented | `nvmlInit` `bridge/init.go:65`; count 4 |
| torch `_raw_device_uuid_nvml` (only when `CUDA_VISIBLE_DEVICES` holds UUIDs) | ctypes `nvmlDeviceGetHandleByIndex_v2`, `nvmlDeviceGetUUID` (`T:torch_cuda___init__.py:1000-1025`) | conditional | implemented | as above |
| triton `NvidiaDriver.is_active()` via `V:vllm/triton_utils/importing.py:31-35` | `torch.cuda.is_available()` (`T:triton_nvidia_driver.py:356-359`) | yes, at import | answered by Mokka NVML (step 1) | True, so Triton stays enabled; no "0 active driver(s)" line |
| `import vllm._C_stable_libtorch` via `current_platform.import_kernels()` (`V:vllm/_custom_ops.py:20` -> `cuda.py:237-248`) | ELF `DT_NEEDED libcuda.so.1` (every CUDA extension links `CUDA::cuda_driver`, `V:cmake/utils.cmake:654-655`) plus direct driver calls, e.g. `cuGetProcAddress` in `V:csrc/libtorch_stable/cache_kernels.cu:152` | yes, first import of `vllm._custom_ops` (98 modules import it at top level) | missing (mock exports neither `cuGetProcAddress` nor `_v2`, `M:pkg/gpu/mockcuda/bridge/cuda.go`) | INFERENCE: ImportError, logged as a WARNING and swallowed (`cuda.py:239-244`); text depends on injection mode, see 5.1 |
| `torch.accelerator.set_device_index(cuda:0)` `V:vllm/v1/worker/gpu_worker.py:424` | libcudart (torch's, CUDA 13) `cudaGetDeviceCount` -> libcuda.so.1 `cuGetProcAddress_v2`/`cuInit`/`cuDriverGetVersion` | yes, first CUDA driver contact | missing | fatal RuntimeError, see 5.1 |
| `torch.cuda.mem_get_info` / `MemorySnapshot` `gpu_worker.py:451`; NCCL `:432` | CUDA runtime + NCCL | yes, after `:424` | missing | not reached |
| `nvidia-smi` (`V:vllm/collect_env.py:268,451`) | n/a | no: `vllm collect-env` subcommand and a dev-only router only | binary present | not called by `vllm serve` |
| `/proc/cpuinfo` `__init__.py:169-173` | n/a | no on the CUDA image (only in `cpu_platform_plugin` after `is_cpu`) | n/a | n/a |
| `/sys/devices/system/node/node*/cpulist` `cuda.py:913,944-960` | n/a | no (NUMA path, `numa_bind` default False) | CDI mode bind-mounts the rendered tree over `/sys/devices` (`M:internal/agent/cdi/spec.go:171-200`) | INFERENCE: node dirs may be absent under CDI mode; only matters with `--numa-bind` |
| `/dev/nvidia*` | opened by the real CUDA driver only | n/a | nodes staged as mknod 195:N (`M:internal/agent/gpudriver/stage.go:46-69`); no kernel module behind them in kind | only matters if a real libcuda is loaded |

CPU image (`vllm/vllm-openai-cpu:v0.30.0`): `cuda_platform_plugin` still calls nvmlInit + GetCount x2 +
nvmlShutdown if a `libnvidia-ml.so.1` is present, but `vllm_version_matches_substr("cpu")` forces
`is_cuda=False` (`__init__.py:73-76`); `cpu_platform_plugin` returns CpuPlatform (`:186-221`). Mokka is
inert for the CPU build: prediction is that it serves Qwen2.5-0.5B on CPU exactly as it would without Mokka.

## 4. SGLang v0.5.20

### 4.1 The one fact that decides SGLang

SGLang never sets `PYTORCH_NVML_BASED_CUDA_CHECK`. Search that could have found it, with a positive control:

```
$ grep -rl 'PYTORCH_NVML_BASED_CUDA_CHECK' <sglang-v0.5.20> | wc -l      ->  0
$ grep -rl 'PYTORCH_NVML_BASED_CUDA_CHECK' <vllm-v0.30.0>   | wc -l      ->  3   (positive control; vllm/env_override.py:164 is one)
$ grep -rn 'PYTORCH_NVML_BASED_CUDA_CHECK' M:internal M:deployments M:pkg ->  no output (Mokka does not inject it either)
```

So in SGLang `torch.cuda.is_available()` takes the CUDA-runtime branch: `torch._C._cuda_getDeviceCount()`
(`T:torch_cuda___init__.py:185-188`) -> `at::cuda::device_count()` (`T:torch_csrc_cuda_Module.cpp:143-149`) ->
`c10::cuda::device_count()`, which is `noexcept` and turns a driver failure into 0
(`T:c10_cuda_CUDAFunctions.cpp:107-124`). The real libcudart cannot use Mokka's libcuda (no `cuGetProcAddress`,
section 2.3), or finds no libcuda at all (CDI mode). `is_available()` is False, and every SGLang hardware probe is
gated on it:

- `is_cuda()` = `torch.cuda.is_available() and torch.version.cuda is not None` (`S:python/sglang/srt/utils/common.py:155-157`),
  evaluated at import time by 94 modules (`grep -rln '^_is_cuda = is_cuda()' S:python/sglang/srt | wc -l` -> 94).
- Platform selection: `_is_cuda_available()` (`S:python/sglang/srt/platforms/__init__.py:34-35`) is False, so
  `_resolve_platform` falls through to the base `SRTPlatform()` (`:126-147`).
- Capability probes `get_device_sm` (`common.py:623-627`), `get_device_capability` (`common.py:987-990`),
  `is_sm100_supported`/`is_blackwell` (`common.py:264-301`) all check `is_cuda()`/`is_available()` first and use
  `torch.cuda.get_device_capability`, never NVML.

Consequence: Mokka's NVML and nvidia-smi are invisible to SGLang's default serve path. SGLang reads no vr200 value.

### 4.2 Serve path

1. `python -m sglang.launch_server` -> `load_plugins()`, `prepare_server_args()` (parse only;
   `S:python/sglang/launch_server.py:79-81`, `S:python/sglang/srt/server_args.py:690-730`).
2. `run_server` -> `server_args.resolve_once()` (`launch_server.py:29`) -> resolution pipeline
   (`S:python/sglang/srt/arg_groups/pipeline.py`). `run_hook(handle_missing_default_values)` is at `pipeline.py:145`.
3. `handle_missing_default_values`: when `--device` is not given, `device=get_device()`
   (`S:python/sglang/srt/arg_groups/serving_hook.py:591-596`).
4. `get_device()` (`common.py:896-949`): not CPU (`SGLANG_USE_CPU_ENGINE` unset, `common.py:219-221`), CUDA not
   available, no XPU/NPU/HPU/MUSA/MPS, then `current_platform.get_device()` on the base platform raises
   `NotImplementedError` (`S:python/sglang/srt/platforms/device_mixin.py:181-183`), and `get_device()` re-raises
   it as `RuntimeError("No accelerator (CUDA, XPU, HPU, NPU, MUSA, MPS) or platform plugin is available.")`
   (`common.py:944-949`). This is in the launcher process, before any scheduler subprocess, weight download
   aside (`handle_model_source_paths`, `pipeline.py:129`, runs earlier).

### 4.3 Table

`nvidia-ml-py` is unpinned in `S:python/pyproject.toml:57`, so the installed wrapper version in the image is
unknown statically; the C symbol column uses vLLM's vendored 12.570.86 mapping (`P:`) as the reference.

| Call (Python site file:line) | C symbol | On serve path? | Mokka | vr200 value / return (file:line) |
|---|---|---|---|---|
| `is_cuda()` -> `torch.cuda.is_available()` `common.py:157` (and `platforms/__init__.py:35`) | libcudart `cudaGetDeviceCount` -> `libcuda.so.1` (`cuGetProcAddress_v2` ...) | yes, at import, first hardware touch | missing (no driver entry points; CDI mode mounts no libcuda at all) | returns 0 without raising, so `is_available()` = False (`T:c10_cuda_CUDAFunctions.cpp:32-39,107-124`) |
| `get_device()` `common.py:896-949` via `serving_hook.py:595` | none | yes | n/a | raises `RuntimeError: No accelerator (CUDA, XPU, HPU, NPU, MUSA, MPS) or platform plugin is available.` (`common.py:947-949`) |
| `get_nvgpu_memory_capacity()` `common.py:663-698`: `nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits` | NVML memory info via nvidia-smi | no: gated by `is_cuda()` at `common.py:832`; `device=="cuda"` then falls to `gpu_mem=None` (`:846-848`) | binary present; `nvmlDeviceGetMemoryInfo`/`_v2` implemented | INFERENCE: would print `294912` per GPU (309237645312 / 2^20; `vr200.yaml:118`), or `40960` under the A100 fallback |
| `_cuda_mem_fallback` -> `torch.cuda.mem_get_info` `common.py:630-660` | CUDA runtime | no (same gate) | missing | would raise the torch driver error |
| `get_nvidia_driver_version_str()` `common.py:1107-1126`: `nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits` | NVML `nvmlSystemGetDriverVersion` via nvidia-smi | no: callers are `check_env.py:196-198` and the gpt-oss override (`arg_groups/model_overrides/gpt_oss.py:115`) | implemented (`bridge/system.go:39`) | `615.23` (`vr200.yaml:23`) |
| `get_device_sm_nvidia_smi()` `common.py:1171-1190`: `nvidia-smi --query-gpu=compute_cap --format=csv,noheader` | NVML CC via nvidia-smi | no: no callers (`grep -rn get_device_sm_nvidia_smi` prints only the def) | implemented | INFERENCE: `10.7` |
| NUMA auto-bind `numa_utils.py:125-152` -> `_query_numa_node_for_gpu` `:400-441`: `nvmlInit`, `nvmlDeviceGetHandleByIndex`, `nvmlDeviceGetMemoryAffinity(NODE)`; reads `/sys/devices/system/node/node*` (`:370`, `:414`) | `nvmlInitWithFlags`, `nvmlDeviceGetHandleByIndex_v2`, `nvmlDeviceGetMemoryAffinity` (`P:2742`) | no: `_is_numa_available()` returns False when `not _is_cuda` (`numa_utils.py:366-367`), although `SGLANG_AUTO_NUMA_BIND` and `SGLANG_NUMA_BIND_V2` default True (`S:python/sglang/srt/environ.py:1442-1443`) | implemented (`bridge/affinity.go:88`) | NUMA 0 or 1 (`vr200.yaml:542-553`) |
| custom all-reduce P2P `S:python/sglang/srt/distributed/device_communicators/custom_all_reduce_utils.py:344-386` | `nvmlDeviceGetHandleByIndex_v2`, `nvmlDeviceGetP2PStatus` (`P:4640`) | no (TP>1 only) | implemented (`bridge/nvlink.go:57`) | P2P OK (`engine/device.go:1599-1615`) |
| fabric clique `S:python/sglang/srt/utils/cuda_vmm_utils.py:162-200` | `nvmlDeviceGetGpuFabricInfoV` (`P:5832`) / `nvmlDeviceGetGpuFabricInfo` (`P:5826`) | no (DWDP / custom all-reduce only) | implemented (`bridge/fabric.go:75`, `:52`) | clique 32766, cluster `00000000-0000-0000-0000-000000000001` (`vr200.yaml:78-79`) |
| `from sgl_kernel import ...` (21 unconditional top-level imports, e.g. `layers/attention/merge_state.py:4`) | ELF deps of `sglang-kernel==0.4.7` (`pyproject.toml:80`) | not before step 4: those modules belong to model/attention code the launcher has not imported yet | n/a | not reached (INFERENCE: not traced import-by-import) |
| `python -m sglang.check_env` (`S:python/sglang/check_env.py`, nvidia-smi + pynvml) | various | no: a separate command | mostly implemented | not on the serve path |

CPU image `lmsysorg/sglang:v0.5.20-xeon`: amd64 only (CONTEXT pinned facts). On the arm64 kind nodes the
prediction is an image pull failure ("no match for platform in manifest"), before any Python runs. Not a Mokka
question.

## 5. PREDICTION

These are the numbers and strings the live ladder should prove wrong. "vr200 loaded" means `nvidia-smi -L`
inside the engine pod lists 4 x `NVIDIA Graphics Device`; section 2.4 explains why it might list
`Mock NVIDIA A100-SXM4-40GB` devices instead.

### 5.1 vLLM `vllm/vllm-openai:v0.30.0`, `vllm serve Qwen/Qwen2.5-0.5B-Instruct`, TP=1, pod with a GPU

1. NVML answers every discovery call; none fails. Fingerprints in the API server log:
   - `Chunked prefill is enabled with max_num_batched_tokens=16384.` (`V:vllm/config/scheduler.py:289`),
     because NVML total 309237645312 >= 160 GiB (`V:vllm/engine/arg_utils.py:2730-2739`). With the A100 fallback
     (40 GiB) or a failed query it is `2048` instead (`:2750-2755`). This one line tells us which profile vLLM read.
   - No "Detected different devices" warning (4 identical names), no dtype-fallback warning (bf16 allowed at CC
     10.7), no "Triton is installed but 0 active driver(s)" line (Triton's `is_active()` is answered by NVML
     through `PYTORCH_NVML_BASED_CUDA_CHECK=1`).
2. First call Mokka cannot satisfy, in time order (non-fatal): the ELF load of `vllm._C_stable_libtorch`
   (`DT_NEEDED libcuda.so.1`; `cuGetProcAddress` referenced directly at `V:csrc/libtorch_stable/cache_kernels.cu:152`,
   built into that extension per `V:CMakeLists.txt:427,451`). vLLM swallows it (`V:vllm/platforms/cuda.py:239-244`):
   `WARNING ... Failed to import from vllm._C_stable_libtorch: ImportError(...)` with
   - CDI mode: `libcuda.so.1: cannot open shared object file: No such file or directory`
   - NRI mode: `..._C_stable_libtorch.abi3.so: undefined symbol: cu...` (most likely `cuGetProcAddress_v2`;
     INFERENCE on the exact name, which is the first unresolved relocation the loader hits).
   If instead the import succeeds, some real `libcuda.so.1` (for example a CUDA forward-compat copy) is on the
   loader path, and step 3 fails with a different code.
3. First FATAL call: EngineCore, `Worker.init_device`, `V:vllm/v1/worker/gpu_worker.py:424`
   `torch.accelerator.set_device_index(cuda:0)` -> `torch.cuda._lazy_init()` -> `torch._C._cuda_init()` ->
   `device_count_ensure_non_zero()`. Line `:415` passes first, because `torch.accelerator.device_count()` is
   NVML-backed and returns 4. Expected text (`T:c10_cuda_CUDAFunctions.cpp:40-44`):
   `RuntimeError: Found no NVIDIA driver on your system. Please check that you have an NVIDIA GPU and installed a driver from http://www.nvidia.com/Download/index.aspx`
   followed in the API server by `RuntimeError: Engine core initialization failed. See root cause above. Failed core proc(s): ...`
   (`V:vllm/v1/engine/utils.py:1320-1323`).
   Lower-confidence alternatives from the same switch: `The NVIDIA driver on your system is too old (found version N)`
   (if cudart reports a non-zero driver version), `CUDA driver initialization failed, you might not have a CUDA gpu.`
   (cudaErrorInitializationError). The basis for the primary pick is Mokka's own measurement in
   `M:docs/cuda-mock.md` (cudaErrorInsufficientDriver with and without the mock) plus the CUDA contract that
   `cudaDriverGetVersion` reports 0 when no usable driver is loaded (INFERENCE: not verified against cudart 13).
4. Not reached: NCCL init (`:432`), `MemorySnapshot` (`:451`), attention backend selection (FLASHINFER first for
   major 10, `cuda.py:158-166`), weight load.

CPU image `vllm/vllm-openai-cpu:v0.30.0`: Mokka is inert. `cuda_platform_plugin` rejects CUDA because the version
string contains "cpu" (`V:vllm/platforms/__init__.py:73-76`), and CpuPlatform serves the model as it would without
Mokka.

### 5.2 SGLang `lmsysorg/sglang:v0.5.20`, `python -m sglang.launch_server --model-path Qwen/Qwen2.5-0.5B-Instruct`

1. Zero NVML calls and zero nvidia-smi invocations by SGLang code before it dies. With `MOCK_NVML_DEBUG=1`
   in the pod env (`M:pkg/gpu/mocknvml/bridge/helpers.go:103`), the SGLang process should print no `[NVML]` lines
   at all. vLLM under the same flag prints many.
2. First call Mokka cannot satisfy: `torch.cuda.is_available()` at import (`common.py:157`), which silently
   returns False (no exception, no warning, if cudart reports cudaErrorInsufficientDriver with driver version 0;
   `T:c10_cuda_CUDAFunctions.cpp:32-39`). If cudart returns another code, a one-time
   `UserWarning: CUDA initialization: ...` appears (`:116-120`) and the outcome is the same.
3. First FATAL call, in the launcher during argument resolution:
   `RuntimeError: No accelerator (CUDA, XPU, HPU, NPU, MUSA, MPS) or platform plugin is available.`
   (`S:python/sglang/srt/utils/common.py:947-949`, via `serving_hook.py:595`). No scheduler process starts.
4. Variant the ladder can try in one step (INFERENCE, not fully traced): with `PYTORCH_NVML_BASED_CUDA_CHECK=1` in
   the pod env, `is_available()` becomes NVML-backed and True, so SGLang advances. It then runs
   `nvidia-smi --query-gpu=memory.total ...` (`pipeline.py:234` -> `memory_hook.py:78` -> `common.py:833`) and gets
   `294912` per GPU, and dies at the first `torch.cuda.get_device_capability()` inside a resolution hook, no later
   than `get_platform().is_hopper_with_cuda_12_3` in `get_default_attn_backend`
   (`S:python/sglang/srt/arg_groups/model_override_base.py:323`, reached for an MHA model such as Qwen via
   `_attention_backend_default`, `overrides.py:1157-1165`, at `pipeline.py:259`; the probe calls
   `torch.cuda.get_device_capability()` at `common.py:270`), with the same
   `Found no NVIDIA driver on your system...` as vLLM. An earlier hook between `pipeline.py:234` and `:259` may
   get there first; not traced. With `--device cuda` and no env change, `get_device()` is
   skipped, but `is_cuda()` stays False (cached at import), so no nvidia-smi either; the failure moves to the
   scheduler's `set_device` (`S:python/sglang/srt/model_executor/model_runner.py:417`).

### 5.3 One-line answer for the chief

For both engines, NVML is not the gap: every NVML symbol either engine calls is exported and answers with vr200
data (when the profile loads). The gap is the CUDA driver API. Mokka's `libcuda.so.1` has no `cuGetProcAddress`,
so torch's real libcudart cannot initialize. vLLM believes in the 4 GPUs (NVML-based availability) and dies at the
worker's first `set_device`. SGLang never believes in them (runtime-based availability) and dies earlier, during
argument resolution, without reading any NVML value.

## 6. Concerns / inferences

1. CONTEXT correction: the CUDA mock lives at `M:pkg/gpu/mockcuda`, not `shims/libcuda`
   (`ls M:shims` -> `libibmock libmockfs nvidia-imex-shim`). Same 15 exports as CONTEXT lists.
2. Config fallback under CDI mode (section 2.4) is INFERENCE from source. If true, every vr200 value in these
   tables becomes a `Mock NVIDIA A100-SXM4-40GB` value (CC 8.0, 40960 MiB) under CDI mode, and fingerprint
   5.1.1 reads `2048`. Check
   `nvidia-smi -L` in the engine pod before reading anything else.
3. `/dev/nvidia<minor>` filtering (`M:pkg/gpu/mocknvml/engine/engine.go:698-726`): a pod that gets only some
   device nodes sees that many GPUs, mapped by vr200's non-identity minors (index 1 is `/dev/nvidia3`). A 1-GPU
   pod should see count 1, not 4.
4. The libcudart behaviour against a libcuda without `cuGetProcAddress` (error 35, driver version 0) is
   INFERENCE; the only measurement is Mokka's own, against a static cudart 12.5 (`M:docs/cuda-mock.md`), not
   torch's dynamic cudart 13.
5. Risk, INFERENCE (low confidence): the mock NVML is a Go `c-shared` library. vLLM loads it in the API server
   (pynvml at platform detection) and then starts EngineCore through `get_mp_context()`
   (`V:vllm/v1/engine/utils.py:164,190`), which is `fork` by default (`V:vllm/envs.py:68`,
   `V:vllm/utils/system_utils.py:126-175`: spawn is forced only for CUDA-initialized, Ray, NUMA-bind or WSL).
   The child inherits a running Go runtime with only the forking thread; Go does not support re-entering its
   runtime in such a child, and a lock held by a vanished runtime thread would hang the first NVML call there.
   If EngineCore stalls with no traceback, retry with `VLLM_WORKER_MULTIPROC_METHOD=spawn`.
   Under NRI mode, a second Go runtime (the mock `libcuda.so.1`) can load into the same process when cudart
   dlopens it; that is a separate risk.
6. Risk, INFERENCE: NRI mode also places `libcudart.so.12 -> libcuda.so.1` on `LD_LIBRARY_PATH`
   (`M:internal/agent/gpudriver/stage.go:148-156`). Both images default to CUDA 13.0.3 builds
   (`V:docker/versions.json` CUDA_VERSION 13.0.3; `S:docker/Dockerfile:1`), whose torch wants `libcudart.so.13`, so
   the symlink should not match. A cu12 image variant could resolve `libcudart.so.12` to the mock and fail at
   `import torch` with an undefined `cuda*` symbol. Whether the torch wheel uses RPATH or RUNPATH decides this.
7. vLLM's vendored pynvml is 12.570.86 (`P:4`); SGLang's is unpinned. No version-dependent symbol is on either
   default path, so the difference does not change a prediction.
8. Scope: vLLM TP=1 path traced end to end to the fatal call. SGLang default path traced to the fatal call;
   the variants in 5.2.4 are traced only to the first hook named.
