# Task C report: vLLM ladder on a Mokka vr200 node

Status: DONE_WITH_CONCERNS (concerns in "Anomalies and concerns" at the end; the main one:
the discovery results in rung 2 need an extra exposure (c) that puts the image's own CUDA compat
`libcuda` on the path, because in both LADDER exposures `import vllm` itself fails)

- Cluster / context: mokka-vr200-llm / kind-mokka-vr200-llm
- Node: mokka-vr200-llm-worker (`spike.mokka/track=vllm`), namespace `spike-vllm`, pod `vllm-ladder`
- Image: `docker.io/vllm/vllm-openai:v0.30.0`, imageID
  `docker.io/vllm/vllm-openai@sha256:8a69ffad015f138d7170c4ddc429e230a3bc1c1719f67e14324749df200a4b90`
  (manifest list; arm64 manifest `sha256:4864d46625cb...`, node image id `sha256:91d9b077589e...`)
- Engine version printed by the engine: `VLLM 0.30.0 /usr/local/lib/python3.12/dist-packages/vllm/__init__.py`
  (probe) and the serve banner `version 0.30.0` / `Initializing a V1 LLM engine (v0.30.0)`; torch `2.13.0+cu130`
- Scratch files: /tmp/vr200-llm-spike-58fc971e/c-* and c-out/
- Ladder pod `spike-vllm/vllm-ladder` DELETED at 2026-09-23T07:52:49Z (concern 5)

How far vLLM can be tested with CURRENT Mokka, in brief. With the stock image and Mokka's driver
directory, as task A injects it, vLLM gets no further than `import vllm`. Only its NVML platform
probe runs ("Confirmed CUDA platform is available"). Its compiled extension then fails to link against
Mokka's `libcuda.so.1` (`undefined symbol: cuPointerGetAttribute`), or finds no `libcuda.so.1` at all.
vLLM's hardware-discovery layer is fully answerable by Mokka's NVML: with a real `libcuda` on the path
it concludes vr200 correctly and resolves the whole engine config. That layer is only reachable if
something outside current Mokka supplies a `libcuda.so.1` exporting the driver symbols vLLM's
extensions link against.

Exposures: (a) FULL = mock NVML + Mokka CUDA shim; (b) NVML-ONLY = mock NVML, no libcuda;
(c) COMPAT (extra) = mock NVML + the image's own CUDA 13 forward-compat `libcuda.so.580.95.05`.

| Rung | Exposure | Result | Decisive evidence line |
|---|---|---|---|
| 1 scheduled + GPUs visible | pod default (FULL) | PASS | `NVIDIA Graphics Device, 294912 MiB, 10.7, 615.23` (x4); pod Running on mokka-vr200-llm-worker |
| 2 vLLM hardware discovery | (a) FULL | FAIL | `Confirmed CUDA platform is available.` then `ImportError: ..._C_stable_libtorch.abi3.so: undefined symbol: cuPointerGetAttribute` at `import vllm` |
| 2 vLLM hardware discovery | (b) NVML-ONLY | FAIL | `Confirmed CUDA platform is available.` then `ImportError: libcuda.so.1: cannot open shared object file` at `import vllm` |
| 2 vLLM hardware discovery | (c) COMPAT | PASS | `PLATFORM NvmlCudaPlatform`, `DeviceCapability(major=10, minor=7)`, `309237645312`, `is_fully_connected -> True`, `supports_fp8 -> True`, `cutlass_fp4_supported -> True`, backend `FLASHINFER`, `TORCH_CUDA_IS_INITIALIZED False` |
| 2 collect_env | all | FAIL | no GPU section; (c) `torch.cuda.init()` -> `No CUDA GPUs are available` |
| 3 torch CUDA init | (a) FULL | FAIL | `avail False` / `count 4` / `RuntimeError: Found no NVIDIA driver on your system`; loaded torch's `libcudart.so.13` + Mokka `libcuda.so.1` |
| 3 torch CUDA init | (b) NVML-ONLY | FAIL | same error; `libcuda.so.1` searched, not found anywhere |
| 3 torch CUDA init | (c) COMPAT | FAIL | `RuntimeError: No CUDA GPUs are available`; compat `libcuda.so.1` loaded, `cuInit(0) -> 100` |
| 4 vllm serve | (a) FULL | FAIL | 2 s: `ImportError: ...undefined symbol: cuPointerGetAttribute` (in the `vllm` CLI import) |
| 4 vllm serve | (b) NVML-ONLY | FAIL | 2 s: `ImportError: libcuda.so.1: cannot open shared object file` |
| 4 vllm serve | (c) COMPAT | FAIL (got furthest) | config resolved (`max_num_batched_tokens=16384`), EngineCore `gpu_worker.py:424 set_device_index` -> `RuntimeError: No CUDA GPUs are available` |
| 5 /v1/completions | - | NOT RUN | no exposure reached "listening" |

## Preparation (done while the image pulled)

Source: sparse shallow clone of the tag, `/tmp/vr200-llm-spike-58fc971e/c-vllm-src`.

```
$ git ls-remote --tags https://github.com/vllm-project/vllm.git 'refs/tags/v0.30.0*'
ced6857afa0ea7b2e3f0846a62e1394e90f15607	refs/tags/v0.30.0
$ git -C c-vllm-src log -1 --format='%H %cd'
ced6857afa0ea7b2e3f0846a62e1394e90f15607 Mon Sep 21 15:32:49 2026 -0700
```

The arm64 image config (registry read, `c-image-config-arm64.json`) carries
`VLLM_BUILD_COMMIT=ced6857afa0ea7b2e3f0846a62e1394e90f15607`, the same commit, so the
clone is the source of the installed package. Other image config values that
matter here: `CUDA_VERSION=13.0.2`, `TORCH_CUDA_ARCH_LIST=8.0 8.7 8.9 9.0 10.0 11.0 12.0`
(no 10.7), `VLLM_ENABLE_CUDA_COMPATIBILITY=0`, entrypoint `vllm serve`,
`LD_LIBRARY_PATH=/usr/local/nvidia/lib64:/usr/local/cuda/lib64:/usr/local/cuda/lib64:/usr/local/nvidia/lib:/usr/local/nvidia/lib64:/usr/local/cuda/lib64`.

Source facts the probes are built on (all at ced6857):

- `vllm/platforms/__init__.py:59-107` `cuda_platform_plugin()`: `import_pynvml()`,
  `nvmlInit()`, `nvmlDeviceGetCount() > 0` (called twice), `nvmlShutdown()`.
- `vllm/platforms/cuda.py:23` imports the compiled extension
  `vllm._C_stable_libtorch` at module top level with no try/except
  (`import vllm._C_stable_libtorch  # noqa`). Only the later copy in
  `import_kernels()` (`cuda.py:240`) is guarded. So resolving `current_platform`
  to `CudaPlatform` requires that extension to load.
- `cuda.py:1065-1079`: `nvmlInit()` succeeds -> `CudaPlatform = NvmlCudaPlatform`,
  then `CudaPlatform.log_warnings()` runs at import (nvmlDeviceGetCount, names).
- `NvmlCudaPlatform` (`cuda.py:780-1027`) reads through NVML only:
  `get_device_capability` -> `nvmlDeviceGetCudaComputeCapability`,
  `get_device_name` -> `nvmlDeviceGetName`, `get_device_total_memory` ->
  `nvmlDeviceGetMemoryInfo().total`, `is_fully_connected` -> `nvmlDeviceGetP2PStatus(..., NVLINK)`,
  `get_device_numa_node` -> `nvmlDeviceGetNumaNodeId` then `nvmlDeviceGetCpuAffinity`
  fallback, `get_all_gpu_pci_bus_ids` -> `nvmlDeviceGetPciInfo`.
- Capability gates: `supports_fp8()` = `has_device_capability(89)` (`cuda.py:617`);
  `support_deep_gemm()` = cap 9.0 or family 10.x or family 12.x (`cuda.py:721`);
  `cutlass_fp4_supported()` (`quantization/utils/nvfp4_utils.py:56`) -> compiled op
  `cutlass_scaled_mm_supports_fp4(cap)` which returns true for 100 <= cap < 120 only if
  `cudaRuntimeGetVersion() >= 12080` (`csrc/libtorch_stable/quantization/fp4/nvfp4_scaled_mm_entry.cu:71-87`);
  attention priority for major 10, causal, non-MLA: FLASHINFER, FLASH_ATTN,
  TRITON_ATTN, FLEX_ATTENTION, TURBOQUANT (`cuda.py:158-166`).
- `supports_trtllm_attention()` (`vllm/utils/flashinfer.py:592`) first calls
  `has_nvidia_artifactory()`, which does an HTTP GET to NVIDIA's artifactory unless
  `flashinfer_cubin` is installed (`flashinfer.py:564-576`). The probe calls it only
  when `flashinfer_cubin` is present, so it never contacts an external host.
- `vllm/env_override.py:164` sets `PYTORCH_NVML_BASED_CUDA_CHECK=1` on `import vllm`.
- Worker device init: `vllm/v1/worker/gpu_worker.py:360-458`
  (`torch.accelerator.device_count()` assert, `set_device_index`, then NCCL init and
  `MemorySnapshot`).
- `vllm serve` flags exist at this version: `--max-model-len` (`engine/arg_utils.py:899`),
  `--enforce-eager` (`arg_utils.py:908`); still re-checked with `vllm serve --help=all` in the pod.

Mock side (Mokka worktree at 8058e1c9):

- The mock CUDA shim exports exactly 15 functions, one of them a Driver API symbol
  (`cuInit`); the rest are runtime-API names:
  `grep '^//export' pkg/gpu/mockcuda/bridge/*.go` -> `cuInit cudaDriverGetVersion
  cudaGetDeviceCount cudaSetDevice cudaMalloc cudaFree cudaMemcpy cudaLaunchKernel
  cudaDeviceSynchronize cudaGetErrorString cudaGetLastError cudaPeekAtLastError
  cudaGetDevice cudaDeviceReset cudaRuntimeGetVersion` (count 15).
- `MOCK_NVML_DEBUG` does NOT log every NVML call. It logs at the bridge sites
  (19 `debugLog(` calls in `pkg/gpu/mocknvml/bridge/*.go`) and the engine sites (165 in
  `pkg/gpu/mocknvml/engine/*.go`). `nvmlInit_v2`, `nvmlShutdown` and
  `nvmlDeviceGetCount` have no line of their own: the search
  `grep -rn -E 'debugLog\("\[NVML\] (nvmlInit|nvmlShutdown|nvmlDeviceGetCount|...)' pkg/gpu/mocknvml`
  found `nvmlInitWithFlags`, `GetP2PStatus`, `GetNumaNodeId`, `GetCpuAffinity`,
  `GetCudaComputeCapability`, `GetHandleByUUID`, and no `nvmlInit_v2`/`nvmlShutdown`/`nvmlDeviceGetCount`.
  To get the complete list of NVML entry points a process resolves, rung 2 also runs
  once under `LD_DEBUG=bindings` and keeps the symbols bound into `libnvidia-ml.so.1`.

## Pod and library exposures

Manifest `/tmp/vr200-llm-spike-58fc971e/c-vllm-pod.yaml`: task A's recipe, the
image's own PATH / LD_LIBRARY_PATH appended (read from `crictl inspecti`, below),
`MOCK_NVML_DEBUG=1`, `HF_HOME=/tmp/hf`, `nvidia.com/gpu: 4`, memory request 1Gi and limit 3Gi,
`sleep infinity`, plus an emptyDir at `/opt/nvml-only`. Nothing is baked into the image.

Three library exposures, selected per `kubectl exec` with `env LD_LIBRARY_PATH=...`
(`c-common.sh`; `IMG` = the image's own value
`/usr/local/nvidia/lib64:/usr/local/cuda/lib64:/usr/local/cuda/lib64:/usr/local/nvidia/lib:/usr/local/nvidia/lib64:/usr/local/cuda/lib64`):

| Name | LD_LIBRARY_PATH | What it gives the process |
|---|---|---|
| (a) FULL | `/opt/nvml-mock/driver/usr/lib64:IMG` (the pod default) | mock NVML and the mock CUDA shim as `libcuda.so.1` |
| (b) NVML-ONLY | `/opt/nvml-only:IMG` (only `libnvidia-ml.so*` copied there) | mock NVML, no `libcuda.so.1` at all |
| (c) COMPAT (extra, not in LADDER) | `/opt/nvml-only:/usr/local/cuda-13.0/compat:IMG` | mock NVML, plus the image's own real CUDA forward-compat driver userspace (`libcuda.so.580.95.05`). This is the directory that vLLM's own `VLLM_ENABLE_CUDA_COMPATIBILITY` knob would prepend (`env_override.py:51-95`) |

I added (c) because (a) and (b) both stop vLLM at `import vllm` (rung 2). With (c), the
extension resolves its driver symbols against a real `libcuda`. That lets vLLM's
pure-NVML discovery run unmodified, and it separates two things: what is missing from
Mokka's CUDA shim, and what no userspace library can supply without a GPU.

Static facts about the image, from `c-out/c-static.log`, `c-static-vllm-ldd.log` and `c-static-nm.log`:

```
$ python3 -c '...importlib.metadata...'        (in pod)
/usr/bin/python3 3.12.3
vllm dist 0.30.0
torch dist 2.13.0+cu130
$ ldconfig -p | grep -E 'libcuda\.so|libcudart|libnvidia-ml'
	libcudart.so.13 (libc6,AArch64) => /usr/local/cuda/targets/sbsa-linux/lib/libcudart.so.13
	libcudart.so (libc6,AArch64) => /usr/local/cuda/targets/sbsa-linux/lib/libcudart.so
ldconfig_grep_rc=0                    <- no libcuda.so.1 and no libnvidia-ml in the loader cache
$ find / -xdev \( -name 'libcuda.so*' -o -name 'libcudart.so*' -o -name 'libnvidia-ml.so*' \)
/usr/local/cuda-13.0/compat/libcuda.so
/usr/local/cuda-13.0/compat/libcuda.so.1
/usr/local/cuda-13.0/compat/libcuda.so.580.95.05
/usr/local/cuda-13.0/targets/sbsa-linux/lib/libcudart.so
/usr/local/cuda-13.0/targets/sbsa-linux/lib/libcudart.so.13
/usr/local/cuda-13.0/targets/sbsa-linux/lib/libcudart.so.13.0.96
/usr/local/cuda-13.0/targets/sbsa-linux/lib/stubs/libcuda.so
/usr/local/lib/python3.12/dist-packages/nvidia/cu13/lib/libcudart.so.13
$ ls -l /usr/local/nvidia
ls: cannot access '/usr/local/nvidia': No such file or directory

$ ldd (FULL)   vllm/_C_stable_libtorch.abi3.so | grep -E 'libcuda\.|libcudart'
	libcudart.so.13 => /usr/local/cuda/lib64/libcudart.so.13
	libcuda.so.1 => /opt/nvml-mock/driver/usr/lib64/libcuda.so.1
$ ldd (NVML-ONLY) vllm/_C_stable_libtorch.abi3.so | grep -E 'libcuda\.|libcudart'
	libcudart.so.13 => /usr/local/cuda/lib64/libcudart.so.13
	libcuda.so.1 => not found
(identical libcuda.so.1 DT_NEEDED on _deepselect_C, _flashkda_C, _flashmla_C,
 _flashmla_extension_C, _moe_C_stable_libtorch, _qutlass_C, cumem_allocator;
 libtorch*.so show "not found" under bare ldd only because torch is not on the path; Python loads it first)

$ nm -D --undefined-only vllm/_C_stable_libtorch.abi3.so | grep '^cu[A-Z]'
cuGetProcAddress_v2 cuPointerGetAttribute cuTensorMapEncodeTiled          count=3
$ nm -D --undefined-only vllm/cumem_allocator.abi3.so | grep '^cu[A-Z]'
cuCtxGetCurrent cuCtxSetCurrent cuDeviceGetAttribute cuDevicePrimaryCtxRetain cuGetErrorString
cuMemAddressFree cuMemAddressReserve cuMemCreate cuMemGetAllocationGranularity cuMemMap
cuMemRelease cuMemSetAccess cuMemUnmap                                   count=13
$ nm -D --defined-only /opt/nvml-mock/driver/usr/lib64/libcuda.so.1 | grep '^cu'
cuInit cudaDeviceReset cudaDeviceSynchronize cudaDriverGetVersion cudaFree cudaGetDevice
cudaGetDeviceCount cudaGetErrorString cudaGetLastError cudaLaunchKernel cudaMalloc cudaMemcpy
cudaPeekAtLastError cudaRuntimeGetVersion cudaSetDevice
$ nm -D --defined-only /usr/local/cuda/compat/libcuda.so.1 | grep -c -w cuPointerGetAttribute   (positive control)
1
```

torch's CUDA runtime is `libcudart.so.13` (CUDA 13.0). The mock's `libcudart.so.12 -> libcuda.so.1`
symlink therefore shadows nothing in this image: no process loaded a `libcudart.so.12`
(LD_DEBUG traces in rung 3).

## Rung 1

Script `c-step1-pod.sh`, log `c-out/c-step1.log`.

```
$ docker exec mokka-vr200-llm-worker crictl images | grep vllm-openai
docker.io/vllm/vllm-openai                      v0.30.0              91d9b077589e7       9.69GB
$ docker exec mokka-vr200-llm-worker crictl inspecti docker.io/vllm/vllm-openai:v0.30.0
status.id sha256:91d9b077589e7ebb9399ea8db07787bd40cc04ba96a767f021ffdf3e321ea9a0
status.repoDigests ['docker.io/vllm/vllm-openai@sha256:8a69ffad015f138d7170c4ddc429e230a3bc1c1719f67e14324749df200a4b90']
ENV PATH=/usr/local/cuda/bin:/usr/local/nvidia/bin:/usr/local/cuda/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ENV LD_LIBRARY_PATH=/usr/local/nvidia/lib64:/usr/local/cuda/lib64:/usr/local/cuda/lib64:/usr/local/nvidia/lib:/usr/local/nvidia/lib64:/usr/local/cuda/lib64
ENV VLLM_BUILD_COMMIT=ced6857afa0ea7b2e3f0846a62e1394e90f15607
$ kubectl --context kind-mokka-vr200-llm -n spike-vllm apply -f c-vllm-pod.yaml
pod/vllm-ladder created
$ kubectl ... wait --for=condition=Ready pod/vllm-ladder --timeout=300s
pod/vllm-ladder condition met
$ kubectl ... get pod vllm-ladder -o wide
NAME          READY   STATUS    RESTARTS   AGE   IP           NODE                     NOMINATED NODE   READINESS GATES
vllm-ladder   1/1     Running   0          1s    10.244.1.7   mokka-vr200-llm-worker   <none>           <none>
$ kubectl ... get pod vllm-ladder -o jsonpath='{.status.containerStatuses[0].imageID}'
docker.io/vllm/vllm-openai@sha256:8a69ffad015f138d7170c4ddc429e230a3bc1c1719f67e14324749df200a4b90
$ kubectl ... exec vllm-ladder -- nvidia-smi -L          (stdout; the mock's debug lines on stderr omitted)
GPU 0: NVIDIA Graphics Device (UUID: GPU-307f0000-0000-0000-0000-000000000000)
GPU 1: NVIDIA Graphics Device (UUID: GPU-307f0000-0000-0000-0000-000000000001)
GPU 2: NVIDIA Graphics Device (UUID: GPU-307f0000-0000-0000-0000-000000000002)
GPU 3: NVIDIA Graphics Device (UUID: GPU-307f0000-0000-0000-0000-000000000003)
RC=0
$ kubectl ... exec vllm-ladder -- nvidia-smi --query-gpu=name,memory.total,compute_cap,driver_version --format=csv
name, memory.total [MiB], compute_cap, driver_version
NVIDIA Graphics Device, 294912 MiB, 10.7, 615.23
NVIDIA Graphics Device, 294912 MiB, 10.7, 615.23
NVIDIA Graphics Device, 294912 MiB, 10.7, 615.23
NVIDIA Graphics Device, 294912 MiB, 10.7, 615.23
RC=0
$ kubectl ... exec vllm-ladder -- sh -c 'command -v nvidia-smi; ls -l /dev/nvidia*; env | sort | grep ...'
/opt/nvml-mock/driver/usr/bin/nvidia-smi
crw-rw-rw- 1 root root 195, 0 Sep 23 07:19 /dev/nvidia0
crw-rw-rw- 1 root root 195, 1 Sep 23 07:19 /dev/nvidia1
crw-rw-rw- 1 root root 195, 2 Sep 23 07:19 /dev/nvidia2
crw-rw-rw- 1 root root 195, 3 Sep 23 07:19 /dev/nvidia3
NVIDIA_VISIBLE_DEVICES=GPU-307f0000-0000-0000-0000-000000000001,GPU-...-000000000002,GPU-...-000000000003,GPU-...-000000000000
(no CUDA_VISIBLE_DEVICES)
$ kubectl ... exec vllm-ladder -- sh -c 'cp -a /opt/nvml-mock/driver/usr/lib64/libnvidia-ml.so* /opt/nvml-only/ && ls -l /opt/nvml-only/'
libnvidia-ml.so -> libnvidia-ml.so.1
libnvidia-ml.so.1 -> libnvidia-ml.so.615.23
libnvidia-ml.so.615.23   (14123928 bytes)
RC=0
```

The mock's stderr for the query shows what nvidia-smi read:
`[NVML] nvmlDeviceGetMemoryInfo_v2 -> total=309237645312 reserved=1339031552 used=0`,
`[NVML] nvmlDeviceGetCudaComputeCapability -> 10.7` (x4).

## Rung 2

Script `c-step2-discovery.sh`. The probe `c-r2-discovery.py` goes to `python3 -` with
`VLLM_LOGGING_LEVEL=DEBUG`. Outputs are in `c-out/r2-<MODE>.{out,err}` and
`r2-<MODE>.nvml-bindings.txt`, and `r2-collectenv-<MODE>.*` for collect_env.

### (a) FULL and (b) NVML-ONLY: `import vllm` fails, before any discovery API can be called

vLLM's NVML platform probe runs and succeeds. Then the import dies while it loads the
CUDA extension that `vllm/platforms/cuda.py:23` imports unguarded.
`import vllm` reaches this through `vllm/__init__.py:14` -> `env_override.py:153` ->
`utils/torch_utils.py:75` (`PIN_MEMORY = is_pin_memory_available()`) -> `current_platform`.
So this fails at `import vllm` itself, not only when `current_platform` is used.

(a) FULL, `c-out/r2-FULL.out` + `.err` (probe exit code 1):

```
DEBUG 09-23 07:22:27 [platforms/__init__.py:61] Checking if CUDA platform is available.
DEBUG 09-23 07:22:27 [platforms/__init__.py:84] Confirmed CUDA platform is available.
...
DEBUG 09-23 07:22:27 [platforms/__init__.py:280] Automatically detected platform cuda.
Traceback (most recent call last):
  File "<stdin>", line 23, in <module>                          <- `import vllm`
  File ".../vllm/__init__.py", line 14, in <module>
    import vllm.env_override  # noqa: F401
  File ".../vllm/env_override.py", line 153, in <module>
    from vllm.utils.torch_utils import is_torch_equal, is_torch_equal_or_newer
  File ".../vllm/utils/torch_utils.py", line 75, in <module>
    PIN_MEMORY = is_pin_memory_available()
  File ".../vllm/utils/platform_utils.py", line 45, in is_pin_memory_available
    from vllm.platforms import current_platform
  File ".../vllm/platforms/__init__.py", line 312, in __getattr__
    _current_platform = resolve_obj_by_qualname(platform_cls_qualname)()
  File ".../vllm/platforms/cuda.py", line 23, in <module>
    import vllm._C_stable_libtorch  # noqa
ImportError: /usr/local/lib/python3.12/dist-packages/vllm/_C_stable_libtorch.abi3.so: undefined symbol: cuPointerGetAttribute
command terminated with exit code 1
```

(b) NVML-ONLY: the same trace, and the same DEBUG lines ("Confirmed CUDA platform is available",
"Automatically detected platform cuda"), ending in:

```
ImportError: libcuda.so.1: cannot open shared object file: No such file or directory
command terminated with exit code 1
```

NVML entry points resolved in (a) and (b), from `LD_DEBUG=bindings`, symbols bound into
the mock `libnvidia-ml.so.1`, identical in both:

```
      1 nvmlDeviceGetCount_v2
      1 nvmlInitWithFlags
      1 nvmlShutdown
```

The mock's debug stderr for (a) shows two init/shutdown cycles, which matches
`cuda_platform_plugin()` running twice (`platforms/__init__.py:250` calls each builtin
plugin once in the loop, then `:279` calls the selected one again):

```
   2 [ENGINE] Initialized with 4 devices (4 visible)
   1 [ENGINE] Re-initializing, reusing existing device state
   2 [ENGINE] Shutdown complete
```

A single interpreter retries the failed import with the same result. Check in FULL:
`first import ImportError name= _C_stable_libtorch ... undefined symbol: cuPointerGetAttribute`
/ `second import ImportError name= _C_stable_libtorch ... undefined symbol: cuPointerGetAttribute`.

### (c) COMPAT: vLLM's own discovery, unmodified, answered by the Mokka NVML mock

With a real `libcuda.so.1` (the image's compat copy) on the path, `import vllm` succeeds.
Every discovery call below then runs through vLLM's `NvmlCudaPlatform`. The mock NVML
supplies the values, and no CUDA context is created:
`TORCH_CUDA_IS_INITIALIZED False` at the end. `c-out/r2-COMPAT.out` (probe rc=0), verbatim:

```
DEBUG 09-23 07:26:02 [platforms/__init__.py:84] Confirmed CUDA platform is available.
DEBUG 09-23 07:26:02 [platforms/__init__.py:280] Automatically detected platform cuda.
VLLM 0.30.0 /usr/local/lib/python3.12/dist-packages/vllm/__init__.py
PLATFORM NvmlCudaPlatform device_type= cuda mro= ['NvmlCudaPlatform', 'CudaPlatformBase', 'Platform', 'object']
TORCH 2.13.0+cu130 cuda= 13.0
HASATTR get_device_name True .../vllm/platforms/cuda.py:818
HASATTR get_device_capability True .../vllm/platforms/cuda.py:790
HASATTR get_device_total_memory True .../vllm/platforms/cuda.py:831
HASATTR is_fully_connected True .../vllm/platforms/cuda.py:838
HASATTR get_device_numa_node True .../vllm/platforms/cuda.py:869
HASATTR get_all_device_numa_nodes True .../vllm/platforms/cuda.py:975
HASATTR get_all_gpu_pci_bus_ids True .../vllm/platforms/cuda.py:996
HASATTR has_device_capability True .../vllm/platforms/cuda.py:802
HASATTR supports_fp8 True .../vllm/platforms/cuda.py:616
HASATTR support_deep_gemm True .../vllm/platforms/cuda.py:720
HASATTR get_valid_backends True .../vllm/platforms/cuda.py:386
(all 21 names probed exist; full list in r2-COMPAT.out)
CALL get_device_name(0) -> 'NVIDIA Graphics Device'          (1, 2, 3 identical)
CALL get_device_capability(0) -> DeviceCapability(major=10, minor=7)   (1, 2, 3 identical)
CALL get_device_total_memory(0) -> 309237645312
CALL get_device_uuid(0) -> 'GPU-307f0000-0000-0000-0000-000000000000'
CALL is_fully_connected([0,1,2,3]) -> True
DEBUG ... [platforms/cuda.py:883] NUMA node 0 for GPU 0 has no CPUs (non-CDMM topology), falling back to CPU-affinity-based detection
CALL get_device_numa_node(0) -> None                          (1, 2, 3 also None)
WARNING ... [platforms/cuda.py:984] Could not detect NUMA node for GPU 0, disabling automatic NUMA binding
CALL get_all_device_numa_nodes() -> None
CALL get_all_gpu_pci_bus_ids() -> {0: '00000002:81:00.0', 1: '00000002:C1:00.0', 2: '0000000A:81:00.0', 3: '0000000A:E1:00.0'}
CALL device_count() -> 4
CALL get_cuda_runtime_major() -> 13
CALL has_device_capability(80) -> True
CALL has_device_capability(89) -> True
CALL has_device_capability(90) -> True
CALL has_device_capability(100) -> True
CALL has_device_capability(103) -> True
CALL has_device_capability(107) -> True
CALL has_device_capability(110) -> False
CALL has_device_capability(120) -> False
CALL has_device_capability((10, 7)) -> True
CALL has_device_capability((10, 8)) -> False
CALL is_device_capability(100) -> False
CALL is_device_capability(103) -> False
CALL is_device_capability(107) -> True
CALL is_device_capability_family(90) -> False
CALL is_device_capability_family(100) -> True
CALL is_device_capability_family(120) -> False
CALL supports_fp8() -> True
CALL supports_mx() -> False
CALL fp8_dtype() -> torch.float8_e4m3fn
CALL is_fp8_fnuz() -> False
CALL support_deep_gemm() -> True
CALL supported_dtypes -> [torch.bfloat16, torch.float16, torch.float32]
CALL check_if_supports_dtype(bfloat16) -> None
CAP_INT 107
CALL nvfp4_utils.cutlass_fp4_supported() -> True
CALL marlin_utils_fp4.is_fp4_marlin_supported() -> True
CALL _custom_ops.cutlass_scaled_mm_supports_fp8(107) -> True
CALL _custom_ops.cutlass_scaled_mm_supports_block_fp8(107) -> True
CALL _custom_ops.cutlass_scaled_mm_supports_fp4(107) -> True
CALL flashinfer.has_flashinfer() -> True
CALL flashinfer.has_flashinfer_cubin() -> True
CALL flashinfer.supports_trtllm_attention(is_prefill=True) -> True
CALL import_utils.has_deep_gemm() -> True
CALL deep_gemm.is_deep_gemm_supported() -> True
  VALID prio=0 FLASHINFER
  VALID prio=1 FLASH_ATTN
  VALID prio=2 TRITON_ATTN
  VALID prio=3 FLEX_ATTENTION
  INVALID prio=4 TURBOQUANT: ['kv_cache_dtype not supported']
CALL get_valid_backends(head_size=64,bf16,auto,num_heads=14) -> ['FLASHINFER', 'FLASH_ATTN', 'TRITON_ATTN', 'FLEX_ATTENTION']
CALL selector.get_attn_backend(head_size=64,bf16,auto,num_heads=14) RAISED AssertionError: Current vLLM config is not set. ...
TORCH_CUDA_IS_INITIALIZED False
MAPPED /opt/nvml-only/libnvidia-ml.so.615.23
MAPPED /usr/local/cuda-13.0/compat/libcuda.so.580.95.05
R2_PROBE_END
```

The public `selector.get_attn_backend()` cannot be called outside a vLLM config
context (the AssertionError above). The platform method it delegates to can be. Follow-up,
`c-out/r2-COMPAT-attn.out`:

```
INFO 09-23 07:39:28 [cuda.py:538] Using FLASHINFER attention backend out of potential backends: ['FLASHINFER', 'FLASH_ATTN', 'TRITON_ATTN', 'FLEX_ATTENTION'].
CALL get_attn_backend_cls(None, cfg, num_heads=14) -> vllm.v1.attention.backends.flashinfer.FlashInferBackend
TORCH_CUDA_IS_INITIALIZED False
```

In summary, vLLM's decision layer takes Mokka's vr200 at face value. It treats the device as an
SM 10.x family part at 10.7, with FP8, CUTLASS NVFP4, DeepGEMM, TRT-LLM attention and FlashInfer
all on, bf16 allowed, 288 GiB per GPU, and 4 GPUs fully NVLink-connected.

### (c) COMPAT, extended: more capability-gated decisions (added after the chief's request for a richer rung 2)

Probe `c-r2-extended.py`, output `c-out/r2x-COMPAT.out` (rc=0), verbatim except that the long enum reprs are shortened:

```
CAP_INT 107
CALL get_device_communicator_cls() -> 'vllm.distributed.device_communicators.cuda_communicator.CudaCommunicator'
CALL use_custom_allreduce() -> True
CALL is_pin_memory_available() -> True
CALL get_static_graph_wrapper_cls() -> 'vllm.compilation.cuda_graph.CUDAGraphWrapper'
CALL support_hybrid_kv_cache() -> True
CALL support_static_graph_mode() -> True
CALL opaque_attention_op() -> True
CALL get_punica_wrapper() -> 'vllm.lora.punica_wrapper.punica_gpu.PunicaWrapperGPU'
CALL use_custom_op_collectives() -> True
CALL get_supported_vit_attn_backends() -> [FLASH_ATTN, TRITON_ATTN, TORCH_SDPA, FLASHINFER]
ATTR dist_backend nccl device_control_env_var CUDA_VISIBLE_DEVICES
CALL get_vit_attn_backend(head_size=80,bf16) -> FLASH_ATTN
CALL supports_trtllm_attention(is_prefill=False) -> True
CALL flashinfer.has_flashinfer_moe() -> True
CALL flashinfer.has_flashinfer_cutlass_fused_moe() -> True
CALL flashinfer.has_flashinfer_trtllm_fused_moe() -> True
CALL flashinfer.has_flashinfer_comm() -> True
CALL flashinfer.has_flashinfer_bf16_gemm() -> True
CALL flashinfer.has_flashinfer_cutedsl() -> True
ATTN fp8-kv h128: valid=['FLASHINFER', 'FLASH_ATTN', 'TRITON_ATTN']
ATTN fp8-kv h128:   invalid prio=3 FLEX_ATTENTION: ['kv_cache_dtype not supported']
ATTN fp8-kv h128:   invalid prio=4 TURBOQUANT: ['kv_cache_dtype not supported']
CALL get_attn_backend_cls[fp8-kv h128] -> 'vllm.v1.attention.backends.flashinfer.FlashInferBackend'
QUANT allowed at 107 : awq(min=75) auto_awq(min=75) fp8(min=75) fbgemm_fp8(min=80) fp_quant(min=100) modelopt(min=80) modelopt_fp4(min=75) modelopt_mxfp8(min=80) modelopt_mixed(min=75) auto_gptq(min=60) gptq(min=60) gptq_marlin(min=60) awq_marlin(min=75) humming(min=75) compressed-tensors(min=70) experts_int8(min=80) quark(min=70) moe_wna16(min=70) torchao(min=75) inc(min=60) mxfp4(min=80) gpt_oss_mxfp4(min=80) deepseek_v4_fp8(min=75) online(min=75) fp8_per_tensor(min=75) fp8_per_block(min=75) fp8_per_channel(min=75) int8_per_channel_weight_only(min=75) nvfp4_per_token(min=75) mxfp8(min=80)
QUANT blocked at 107 : (none)
SKIPPED is_integrated_gpu/num_compute_units/is_arch_support_pdl: they call torch.cuda device properties/current_device and would initialise CUDA
TORCH_CUDA_IS_INITIALIZED False
INFO 09-23 07:50:43 [cuda.py:538] Using FLASHINFER attention backend out of potential backends: ['FLASHINFER', 'FLASH_ATTN', 'TRITON_ATTN'].
```

The quantization gate is the one vLLM applies at config time (`vllm/config/vllm.py:836`,
`capability < quant_config.get_min_capability()` -> ValueError). All 30 registered methods pass at 107.

Things I could not evaluate without a GPU:

- MLA attention selection (DeepSeek-style, head 576) cannot be decided from NVML alone. Inside a
  default `VllmConfig`, `get_valid_backends` imports the CUTLASS_MLA backend module, whose
  module-level object calls into CUDA. `c-out/r2x-mla-COMPAT.out`:
  `ATTN mla h576 bf16-kv nh128 RAISED RuntimeError: No CUDA GPUs are available` (the fp8-kv
  variant fails the same way). The traceback ends at
  `vllm/v1/attention/backends/mla/cutlass_mla.py:99 <module>` -> `cutlass_mla.py:71 __init__` -> `torch/cuda/__init__.py:529 _lazy_init`.
- I did not call `is_integrated_gpu()`, `num_compute_units()` or `is_arch_support_pdl()`. They read
  `torch.cuda.get_device_properties` / `current_device`, which would initialise CUDA.

Notes on (c):
- flashinfer's import tried a CUDA call and logged it without failing:
  `Failed to get device capability: No CUDA GPUs are available.` (x2, stderr), from
  `flashinfer/compilation_context.py:108` (`grep -rn "Failed to get device capability"` in site-packages).
- NUMA is `None` because of the kind node, not because of NVML. The mock answered
  `nvmlDeviceGetNumaNodeId -> 0|1` and `nvmlDeviceGetCpuAffinity -> [18446744073709551615]` or
  `[0]`. The linuxkit VM has no NUMA sysfs, though:
  `ls /sys/devices/system/node/` -> `No such file or directory` (nproc 14, cpuset 0-13).
  vLLM uses this only when `numa_bind` is set.
- `supports_trtllm_attention()` made no network call. `has_flashinfer_cubin()` is True
  (`flashinfer-cubin` is installed), so `has_nvidia_artifactory()` returns before its HTTP GET.

NVML entry points resolved in (c), from `LD_DEBUG=bindings` (count = number of distinct
binding sites, not number of calls):

```
     10 nvmlDeviceGetCount_v2
      1 nvmlDeviceGetCpuAffinity
      1 nvmlDeviceGetCudaComputeCapability
      1 nvmlDeviceGetHandleByIndex_v2
      1 nvmlDeviceGetMemoryInfo
      1 nvmlDeviceGetName
      1 nvmlDeviceGetNumaNodeId
      1 nvmlDeviceGetP2PStatus
      1 nvmlDeviceGetPciInfo_v3
      1 nvmlDeviceGetUUID
      9 nvmlInit
      1 nvmlInitWithFlags
      1 nvmlShutdown
```

### `python3 -m vllm.collect_env`

No exposure produced a GPU section. collect_env always calls `torch.cuda.init()` when
`torch.cuda.is_available()` is true (`collect_env.py:685-690`), and in vLLM processes that
check is NVML-based. Results:

- (b) NVML-ONLY: `ImportError: libcuda.so.1: cannot open shared object file` at `import vllm`
  (runpy imports the package first).
- (c) COMPAT: only `Collecting environment information...` on stdout, then
  `collect_env.py:687 torch.cuda.init()` -> `RuntimeError: No CUDA GPUs are available`.
- (a) FULL: in 8 of 10 runs this fails at `import vllm` with the same
  `undefined symbol: cuPointerGetAttribute` as the probe (`r2-collectenv-FULL.rerun{1,2,3}.err`,
  `ce-exp-{A,B,C,D}.err`, plus the `-X importtime` rerun). Twice (`r2-collectenv-FULL.err`,
  `r2-collectenv-FULL.repro.err`), both times right after an `LD_DEBUG=bindings` run of the
  probe, it got past `import vllm`. The mock logged only one NVML init and no vLLM platform
  detection, and the run failed later at `torch.cuda.init()` with
  `RuntimeError: Found no NVIDIA driver on your system`. I could not explain these two runs, and
  a third attempt at the same sequence (`ce-exp-D`) failed at import. Either way no GPU
  section was printed. `vllm serve` does not use collect_env.

## Rung 3

Script `c-step3-torch.sh`. It runs the LADDER one-liner verbatim, then the same one-liner
under `LD_DEBUG=libs` (to a file, filtered to cuda / nvidia-ml), then a guarded variant that
prints `/proc/self/maps` (`c-r3-maps.py`).

| Exposure | `torch.cuda.is_available()` | `device_count()` | `torch.zeros(1, device='cuda')` | libcudart loaded | libcuda.so.1 loaded |
|---|---|---|---|---|---|
| (a) FULL | False | 4 | `RuntimeError: Found no NVIDIA driver on your system` | torch's `nvidia/cu13/lib/libcudart.so.13` | Mokka shim `/opt/nvml-mock/driver/usr/lib64/libcuda.so.1` (`libcuda.so.615.23`) |
| (b) NVML-ONLY | False | 4 | `RuntimeError: Found no NVIDIA driver on your system` | same | none: searched 3 times, not found |
| (c) COMPAT | False | 4 | `RuntimeError: No CUDA GPUs are available` | same | image compat `libcuda.so.580.95.05` |

`device_count()` = 4 comes from NVML: torch counts devices through `libnvidia-ml.so.1`,
which the loader trace shows it loading from the mock. `is_available()` is False because
the CUDA runtime cannot bring up a device.

(a) FULL, verbatim:

```
$ kubectl ... exec -i vllm-ladder -c vllm -- env LD_LIBRARY_PATH=<FULL> python3 -c "import torch; print(torch.__version__, torch.version.cuda); print('avail', torch.cuda.is_available()); print('count', torch.cuda.device_count()); x = torch.zeros(1, device='cuda'); print('alloc ok', x)"
2.13.0+cu130 13.0
avail False
count 4
Traceback (most recent call last):
  File "<string>", line 1, in <module>
  File "/usr/local/lib/python3.12/dist-packages/torch/cuda/__init__.py", line 529, in _lazy_init
    torch._C._cuda_init()
RuntimeError: Found no NVIDIA driver on your system. Please check that you have an NVIDIA GPU and installed a driver from http://www.nvidia.com/Download/index.aspx
command terminated with exit code 1

LD_DEBUG=libs (filtered):
	find library=libcudart.so.13 [0]; searching
	  trying file=/usr/local/lib/python3.12/dist-packages/torch/lib/../../nvidia/cu13/lib/libcudart.so.13
	calling init: /usr/local/lib/python3.12/dist-packages/torch/lib/../../nvidia/cu13/lib/libcudart.so.13
	find library=libcuda.so.1 [0]; searching
	  trying file=/opt/nvml-mock/driver/usr/lib64/libcuda.so.1
	calling init: /opt/nvml-mock/driver/usr/lib64/libcuda.so.1
	find library=libnvidia-ml.so.1 [0]; searching
	  trying file=/opt/nvml-mock/driver/usr/lib64/libnvidia-ml.so.1
	calling init: /opt/nvml-mock/driver/usr/lib64/libnvidia-ml.so.1
maps probe: MAPPED /opt/nvml-mock/driver/usr/lib64/libcuda.so.615.23
            MAPPED /opt/nvml-mock/driver/usr/lib64/libnvidia-ml.so.615.23
            MAPPED /usr/local/lib/python3.12/dist-packages/nvidia/cu13/lib/libcudart.so.13
```

(b) NVML-ONLY: same stdout and the same `Found no NVIDIA driver` error. The loader looked for
`libcuda.so.1` in three passes, in the LD_LIBRARY_PATH entries, torch's RPATH dirs,
`/lib/aarch64-linux-gnu` and `/usr/lib`, and found it nowhere. For example:

```
	find library=libcuda.so.1 [0]; searching
	  trying file=/opt/nvml-only/libcuda.so.1
	  trying file=/usr/local/cuda/lib64/libcuda.so.1
	  trying file=/usr/local/lib/python3.12/dist-packages/nvidia/cu13/lib/libcuda.so.1
	  trying file=/lib/aarch64-linux-gnu/libcuda.so.1
	  trying file=/usr/lib/aarch64-linux-gnu/libcuda.so.1
	  trying file=/lib/libcuda.so.1
	  trying file=/usr/lib/libcuda.so.1
	find library=libnvidia-ml.so.1 [0]; searching
	  trying file=/opt/nvml-only/libnvidia-ml.so.1
	calling init: /opt/nvml-only/libnvidia-ml.so.1
```

(c) COMPAT: the same stdout, then `RuntimeError: No CUDA GPUs are available`. The trace shows
`calling init: /usr/local/cuda-13.0/compat/libcuda.so.1`.

Direct driver calls from ctypes, which show where each libcuda stops:

```
/opt/nvml-mock/driver/usr/lib64/libcuda.so.1: cuInit(0) -> 0
/opt/nvml-mock/driver/usr/lib64/libcuda.so.1: cuDriverGetVersion not exported
/opt/nvml-mock/driver/usr/lib64/libcuda.so.1: cuDeviceGetCount not exported
/usr/local/cuda-13.0/compat/libcuda.so.1: cuInit(0) -> 100          (CUDA_ERROR_NO_DEVICE)
/usr/local/cuda-13.0/compat/libcuda.so.1: cuDriverGetVersion -> 0 version=13000
/usr/local/cuda-13.0/compat/libcuda.so.1: cuDeviceGetCount -> 3 count=-1   (CUDA_ERROR_NOT_INITIALIZED)
```

INFERENCE: in (a), the CUDA 13 runtime finds that the mock `libcuda.so.1` lacks the
driver entry points it resolves (for example `cuGetProcAddress_v2` and `cuDriverGetVersion`,
both absent in the mock export list above). It then reports the "no driver" condition. In (c),
a real driver userspace reaches the kernel layer and finds no GPU (`cuInit` -> 100): the
`/dev/nvidia0..3` nodes are mknod'd placeholders with no kernel driver behind them, and
`/dev/nvidiactl` is not passed into the pod at all (task A 6.5).

### Rung 3: the exact driver symbols asked of `libcuda.so.1`

The chief asked for the precise missing symbols. The torch error text names none, so I re-ran the
same LADDER one-liner under `LD_DEBUG=symbols,bindings`, streamed through `grep libcuda.so`
inside the pod (`c-r3-syms-inpod.sh`, outputs `c-out/r3-<MODE>.cuda-symbols.txt`).

(a) FULL, the Mokka shim: 448 driver (`cu*`) symbols were looked up in
`/opt/nvml-mock/driver/usr/lib64/libcuda.so.1`, and exactly one resolved there:

```
## symbols BOUND to libcuda.so.1
cuInit <- /opt/nvml-mock/driver/usr/lib64/libcuda.so.1
## looked up in libcuda.so.1 but NOT bound there   (cu* names only: 447, full list in c-out/r3-FULL.cuda-missing.txt)
cuGetProcAddress_v2 1        cuGetProcAddress 1        cuDriverGetVersion 1
cuDeviceGetCount 1           cuDeviceGet 1             cuDevicePrimaryCtxRetain 1
cuCtxGetCurrent 1            cuGetExportTable 1        cuPointerGetAttribute 1
cuTensorMapEncodeTiled 1     cuMemAlloc_v2 1           (grep -c -x <name> on the missing list)
```

(c) COMPAT, for comparison, real compat libcuda: 33 symbols were bound by direct lookup, including
`cuGetProcAddress_v2`, `cuDriverGetVersion`, `cuInit`, `cuDeviceGet`, `cuDevicePrimaryCtxRetain`,
`cuDeviceGetAttribute`, `cuModuleLoadData`, `cuLaunchKernel` and `cuTensorMapEncodeTiled`.
The full list is in `c-out/r3-COMPAT.cuda-symbols.txt`.

Limits of this trace. glibc reports a `dlsym(handle, name)` lookup against the handle's own
object, so these lines do not say which library (libcudart, cuda-python's
`cuda/bindings/_internal/driver*.so`, torch) issued each lookup. The non-`cu*` names in the "not
bound" lists are ordinary libc symbols, and the loader resolves them later in the scope chain.
INFERENCE: the gap between 448 lookups in (a) and 33 in (c) means the caller fetches most driver
entry points through `cuGetProcAddress_v2` when it exists, and falls back to one `dlsym` per symbol
when it does not.

## Rung 4

Flag check first. `vllm serve --help=all` itself fails in FULL (the CLI imports `vllm`), so
the flags were checked under COMPAT (`c-out/r4-help-*.out`):

```
=== vllm serve --help=all mode=FULL
rc=1 lines=0
ImportError: /usr/local/lib/python3.12/dist-packages/vllm/_C_stable_libtorch.abi3.so: undefined symbol: cuPointerGetAttribute
=== vllm serve --help=all mode=COMPAT
rc=0 lines=2093
157:  --port PORT           Port number. (default: 8000)
274:  --enforce-eager, --no-enforce-eager
330:  --max-model-len MAX_MODEL_LEN
```

Launch. `c-step4-serve.sh <MODE>` writes `c-serve-inpod.sh` into the pod and runs it detached.
That script runs `timeout 900 vllm serve Qwen/Qwen2.5-0.5B-Instruct --enforce-eager --max-model-len 2048 --port 8000`
with stdout and stderr to `/tmp/serve-<MODE>.log` in the pod, then appends `SERVE_EXIT_RC=<rc>`.
The log is then copied out to `c-out/r4-<MODE>.log`.

| Exposure | Started / exited | First fatal error (verbatim) | Platform detected | Config resolved | Model files | Weights loaded | KV cache profiled | Listening |
|---|---|---|---|---|---|---|---|---|
| (a) FULL | 07:42:37 / 07:42:39, rc=1 | `ImportError: /usr/local/lib/python3.12/dist-packages/vllm/_C_stable_libtorch.abi3.so: undefined symbol: cuPointerGetAttribute` | NVML probe yes, platform class no | no | no | no | no | no |
| (b) NVML-ONLY | 07:42:52 / 07:42:54, rc=1 | `ImportError: libcuda.so.1: cannot open shared object file: No such file or directory` | NVML probe yes, platform class no | no | no | no | no | no |
| (c) COMPAT | 07:43:09 / 07:44:00, rc=1 | EngineCore: `RuntimeError: No CUDA GPUs are available` at `gpu_worker.py:424 torch.accelerator.set_device_index(self.device)` | yes | yes | config and tokenizer only, no `*.safetensors` | no | no | no |

(a) FULL, the whole log apart from the mock NVML lines (`c-out/r4-FULL.log`, 43 lines):

```
SERVE_START 2026-09-23T07:42:37Z mode=FULL LD_LIBRARY_PATH=/opt/nvml-mock/driver/usr/lib64:/usr/local/nvidia/lib64:...
Traceback (most recent call last):
  File "/usr/local/bin/vllm", line 4, in <module>
    from vllm.entrypoints.cli.main import main
  File "/usr/local/lib/python3.12/dist-packages/vllm/__init__.py", line 14, in <module>
    import vllm.env_override  # noqa: F401
  File "/usr/local/lib/python3.12/dist-packages/vllm/env_override.py", line 153, in <module>
    from vllm.utils.torch_utils import is_torch_equal, is_torch_equal_or_newer
  File "/usr/local/lib/python3.12/dist-packages/vllm/utils/torch_utils.py", line 75, in <module>
    PIN_MEMORY = is_pin_memory_available()
  File "/usr/local/lib/python3.12/dist-packages/vllm/utils/platform_utils.py", line 45, in is_pin_memory_available
    from vllm.platforms import current_platform
  File "/usr/local/lib/python3.12/dist-packages/vllm/platforms/__init__.py", line 312, in __getattr__
    _current_platform = resolve_obj_by_qualname(platform_cls_qualname)()
  File "/usr/local/lib/python3.12/dist-packages/vllm/utils/import_utils.py", line 130, in resolve_obj_by_qualname
    module = importlib.import_module(module_name)
  File "/usr/lib/python3.12/importlib/__init__.py", line 90, in import_module
    return _bootstrap._gcd_import(name[level:], package, level)
  File "/usr/local/lib/python3.12/dist-packages/vllm/platforms/cuda.py", line 23, in <module>
    import vllm._C_stable_libtorch  # noqa
ImportError: /usr/local/lib/python3.12/dist-packages/vllm/_C_stable_libtorch.abi3.so: undefined symbol: cuPointerGetAttribute
SERVE_EXIT_RC=1 2026-09-23T07:42:39Z
```

(b) NVML-ONLY: an identical trace (`c-out/r4-NVONLY.log`), ending in
`ImportError: libcuda.so.1: cannot open shared object file: No such file or directory` /
`SERVE_EXIT_RC=1 2026-09-23T07:42:54Z`.

(c) COMPAT (`c-out/r4-COMPAT.log`, 251 lines). The progress lines in order, with the mock's
NVML lines kept where they show what vLLM read:

```
SERVE_START 2026-09-23T07:43:09Z mode=COMPAT LD_LIBRARY_PATH=/opt/nvml-only:/usr/local/cuda-13.0/compat:...
[CONFIG] Loaded YAML config: 4 devices, driver 615.23
[ENGINE] Initialized with 4 devices (4 visible)   (x4 init/shutdown cycles, then 4 x nvmlDeviceGetName = CudaPlatform.log_warnings)
(APIServer pid=2080) INFO 09-23 07:43:20 [api_utils.py:347]  ... version 0.30.0
(APIServer pid=2080) INFO 09-23 07:43:20 [api_utils.py:286] non-default args: {'model_tag': 'Qwen/Qwen2.5-0.5B-Instruct', 'model': 'Qwen/Qwen2.5-0.5B-Instruct', 'max_model_len': 2048, 'enforce_eager': True}
(APIServer pid=2080) Warning: You are sending unauthenticated requests to the HF Hub. Please set a HF_TOKEN to enable higher rate limits and faster downloads.
[NVML] nvmlDeviceGetCudaComputeCapability -> 10.7
(APIServer pid=2080) INFO 09-23 07:43:35 [model.py:692] Resolved architecture: Qwen2ForCausalLM
(APIServer pid=2080) INFO 09-23 07:43:35 [model.py:2030] Using max model len 2048
[NVML] nvmlDeviceGetMemoryInfo -> total=309237645312 used=0
[NVML] nvmlDeviceGetName -> NVIDIA Graphics Device
(APIServer pid=2080) INFO 09-23 07:43:35 [scheduler.py:288] Chunked prefill is enabled with max_num_batched_tokens=16384.
(APIServer pid=2080) WARNING 09-23 07:43:36 [vllm.py:1547] Enforce eager set, disabling torch.compile and CUDAGraphs. ...
(APIServer pid=2080) INFO 09-23 07:43:36 [compilation.py:336] Enabled custom fusions: norm_quant, act_quant
(EngineCore pid=2183) INFO 09-23 07:43:53 [core.py:123] Initializing a V1 LLM engine (v0.30.0) with config: model='Qwen/Qwen2.5-0.5B-Instruct', ... dtype=torch.bfloat16, max_seq_len=2048, ... tensor_parallel_size=1, ... kv_cache_dtype=auto, device_config=cuda, ...
[NVML] nvmlDeviceGetCudaComputeCapability -> 10.7   (x2, EngineCore)
(EngineCore pid=2183) ERROR 09-23 07:43:55 [core.py:1366] EngineCore failed to start.
...
(EngineCore pid=2183) ERROR 09-23 07:43:55 [core.py:1366]   File ".../vllm/v1/worker/gpu_worker.py", line 424, in init_device
(EngineCore pid=2183) ERROR 09-23 07:43:55 [core.py:1366]     torch.accelerator.set_device_index(self.device)
(EngineCore pid=2183) ERROR 09-23 07:43:55 [core.py:1366]   File ".../torch/accelerator/__init__.py", line 198, in set_device_index
(EngineCore pid=2183) ERROR 09-23 07:43:55 [core.py:1366]     torch._C._accelerator_setDeviceIndex(device_index)
(EngineCore pid=2183) ERROR 09-23 07:43:55 [core.py:1366]   File ".../torch/cuda/__init__.py", line 529, in _lazy_init
(EngineCore pid=2183) ERROR 09-23 07:43:55 [core.py:1366]     torch._C._cuda_init()
(EngineCore pid=2183) ERROR 09-23 07:43:55 [core.py:1366] RuntimeError: No CUDA GPUs are available
(APIServer pid=2080) RuntimeError: Engine core initialization failed. See root cause above. Failed core proc(s): {}
SERVE_EXIT_RC=1 2026-09-23T07:44:00Z
```

What the API server resolved from Mokka before the engine died:
`max_num_batched_tokens=16384`, driven by NVML total memory 309237645312 >= 160 GiB (task B cites
`arg_utils.py:2730-2739`), and `dtype=torch.bfloat16` with no dtype-fallback warning. Absence checks on
the same log, each with a positive control:

```
$ grep -c 'Detected different devices' r4-COMPAT.log        -> 0
$ grep -c '0 active driver' r4-COMPAT.log                   -> 0
$ grep -c -i -E 'bfloat16 is only supported|--dtype=half' r4-COMPAT.log   -> 0
$ grep -c 'Chunked prefill is enabled' r4-COMPAT.log        -> 1   (positive control, same file)
```

Files in the pod after (c):

```
$ ls /tmp/hf/hub/models--Qwen--Qwen2.5-0.5B-Instruct/snapshots/*/
config.json  generation_config.json  merges.txt  tokenizer.json  tokenizer_config.json  vocab.json
$ ... | grep -c safetensors
0
```

### Rung 4: the exact missing symbol and which `.so` asked for it

| Exposure | Symbol or library the error names | Asked for by | When |
|---|---|---|---|
| (a) FULL | `undefined symbol: cuPointerGetAttribute` | `/usr/local/lib/python3.12/dist-packages/vllm/_C_stable_libtorch.abi3.so` (the ImportError names it) | at `import vllm` (dynamic link of the extension), before argument parsing |
| (b) NVML-ONLY | `libcuda.so.1: cannot open shared object file` | the same extension: `DT_NEEDED libcuda.so.1` (`ldd` shows `libcuda.so.1 => not found`) | same point |

CPython loads extensions with RTLD_NOW, so the loader stops at the FIRST unresolved symbol. The
complete set this extension needs from `libcuda.so.1` is three symbols (`nm -D --undefined-only`,
Pod section): `cuGetProcAddress_v2 cuPointerGetAttribute cuTensorMapEncodeTiled`. Seven more vLLM
extensions carry `DT_NEEDED libcuda.so.1`. `cumem_allocator.abi3.so` alone needs 13 driver symbols
(`cuCtxGetCurrent ... cuMemUnmap`, listed in the Pod section). So a libcuda mock would have to
satisfy vLLM's extensions at import (link) time, not only at CUDA init.

Memory: no OOM. `kubectl get pod vllm-ladder -o jsonpath='{...restartCount} {...state} {...lastState}'`
-> `0 {"running":{"startedAt":"2026-09-23T07:19:28Z"}} {}`.

<details><summary>(c) COMPAT, last 80 lines of the log verbatim (c-out/r4-COMPAT.tail80.txt)</summary>

```
(EngineCore pid=2183)   File "/usr/local/lib/python3.12/dist-packages/vllm/v1/executor/abstract.py", line 110, in __init__
(EngineCore pid=2183)     self._init_executor()
(EngineCore pid=2183)   File "/usr/local/lib/python3.12/dist-packages/vllm/v1/executor/uniproc_executor.py", line 69, in _init_executor
(EngineCore pid=2183)     self.driver_worker.init_device()
(EngineCore pid=2183)   File "/usr/local/lib/python3.12/dist-packages/vllm/v1/worker/worker_base.py", line 355, in init_device
(EngineCore pid=2183)     self.worker.init_device()  # type: ignore
(EngineCore pid=2183)     ^^^^^^^^^^^^^^^^^^^^^^^^^
(EngineCore pid=2183)   File "/usr/local/lib/python3.12/dist-packages/vllm/tracing/otel.py", line 178, in sync_wrapper
(EngineCore pid=2183)     return func(*args, **kwargs)
(EngineCore pid=2183)            ^^^^^^^^^^^^^^^^^^^^^
(EngineCore pid=2183)   File "/usr/local/lib/python3.12/dist-packages/vllm/v1/worker/gpu_worker.py", line 424, in init_device
(EngineCore pid=2183)     torch.accelerator.set_device_index(self.device)
(EngineCore pid=2183)   File "/usr/local/lib/python3.12/dist-packages/torch/accelerator/__init__.py", line 198, in set_device_index
(EngineCore pid=2183)     torch._C._accelerator_setDeviceIndex(device_index)
(EngineCore pid=2183)   File "/usr/local/lib/python3.12/dist-packages/torch/cuda/__init__.py", line 529, in _lazy_init
(EngineCore pid=2183)     torch._C._cuda_init()
(EngineCore pid=2183) RuntimeError: No CUDA GPUs are available
(APIServer pid=2080) Traceback (most recent call last):
(APIServer pid=2080)   File "/usr/local/bin/vllm", line 10, in <module>
(APIServer pid=2080)     sys.exit(main())
(APIServer pid=2080)              ^^^^^^
(APIServer pid=2080)   File "/usr/local/lib/python3.12/dist-packages/vllm/entrypoints/cli/main.py", line 106, in main
(APIServer pid=2080)     args.dispatch_function(args)
(APIServer pid=2080)   File "/usr/local/lib/python3.12/dist-packages/vllm/entrypoints/cli/serve.py", line 154, in cmd
(APIServer pid=2080)     uvloop.run(run_server(args))
(APIServer pid=2080)   File "/usr/local/lib/python3.12/dist-packages/uvloop/__init__.py", line 96, in run
(APIServer pid=2080)     return __asyncio.run(
(APIServer pid=2080)            ^^^^^^^^^^^^^^
(APIServer pid=2080)   File "/usr/lib/python3.12/asyncio/runners.py", line 194, in run
(APIServer pid=2080)     return runner.run(main)
(APIServer pid=2080)            ^^^^^^^^^^^^^^^^
(APIServer pid=2080)   File "/usr/lib/python3.12/asyncio/runners.py", line 118, in run
(APIServer pid=2080)     return self._loop.run_until_complete(task)
(APIServer pid=2080)            ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
(APIServer pid=2080)   File "uvloop/loop.pyx", line 1518, in uvloop.loop.Loop.run_until_complete
(APIServer pid=2080)   File "/usr/local/lib/python3.12/dist-packages/uvloop/__init__.py", line 48, in wrapper
(APIServer pid=2080)     return await main
(APIServer pid=2080)            ^^^^^^^^^^
(APIServer pid=2080)   File "/usr/local/lib/python3.12/dist-packages/vllm/entrypoints/launchers/api_server/entry.py", line 176, in run_server
(APIServer pid=2080)     await run_server_worker(listen_address, sock, args, **uvicorn_kwargs)
(APIServer pid=2080)   File "/usr/local/lib/python3.12/dist-packages/vllm/entrypoints/launchers/api_server/entry.py", line 190, in run_server_worker
(APIServer pid=2080)     async with build_async_engine_client(
(APIServer pid=2080)   File "/usr/lib/python3.12/contextlib.py", line 210, in __aenter__
(APIServer pid=2080)     return await anext(self.gen)
(APIServer pid=2080)            ^^^^^^^^^^^^^^^^^^^^^
(APIServer pid=2080)   File "/usr/local/lib/python3.12/dist-packages/vllm/entrypoints/launchers/api_server/entry.py", line 58, in build_async_engine_client
(APIServer pid=2080)     async with build_async_engine_client_from_engine_args(
(APIServer pid=2080)   File "/usr/lib/python3.12/contextlib.py", line 210, in __aenter__
(APIServer pid=2080)     return await anext(self.gen)
(APIServer pid=2080)            ^^^^^^^^^^^^^^^^^^^^^
(APIServer pid=2080)   File "/usr/local/lib/python3.12/dist-packages/vllm/entrypoints/launchers/api_server/entry.py", line 94, in build_async_engine_client_from_engine_args
(APIServer pid=2080)     async_llm = AsyncLLM.from_vllm_config(
(APIServer pid=2080)                 ^^^^^^^^^^^^^^^^^^^^^^^^^^
(APIServer pid=2080)   File "/usr/local/lib/python3.12/dist-packages/vllm/v1/engine/async_llm.py", line 235, in from_vllm_config
(APIServer pid=2080)     return cls(
(APIServer pid=2080)            ^^^^
(APIServer pid=2080)   File "/usr/local/lib/python3.12/dist-packages/vllm/v1/engine/async_llm.py", line 169, in __init__
(APIServer pid=2080)     self.engine_core = EngineCoreClient.make_async_mp_client(
(APIServer pid=2080)                        ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
(APIServer pid=2080)   File "/usr/local/lib/python3.12/dist-packages/vllm/tracing/otel.py", line 178, in sync_wrapper
(APIServer pid=2080)     return func(*args, **kwargs)
(APIServer pid=2080)            ^^^^^^^^^^^^^^^^^^^^^
(APIServer pid=2080)   File "/usr/local/lib/python3.12/dist-packages/vllm/v1/engine/core_client.py", line 163, in make_async_mp_client
(APIServer pid=2080)     return AsyncMPClient(
(APIServer pid=2080)            ^^^^^^^^^^^^^^
(APIServer pid=2080)   File "/usr/local/lib/python3.12/dist-packages/vllm/tracing/otel.py", line 178, in sync_wrapper
(APIServer pid=2080)     return func(*args, **kwargs)
(APIServer pid=2080)            ^^^^^^^^^^^^^^^^^^^^^
(APIServer pid=2080)   File "/usr/local/lib/python3.12/dist-packages/vllm/v1/engine/core_client.py", line 1060, in __init__
(APIServer pid=2080)     super().__init__(
(APIServer pid=2080)   File "/usr/local/lib/python3.12/dist-packages/vllm/v1/engine/core_client.py", line 656, in __init__
(APIServer pid=2080)     with launch_core_engines(
(APIServer pid=2080)   File "/usr/lib/python3.12/contextlib.py", line 144, in __exit__
(APIServer pid=2080)     next(self.gen)
(APIServer pid=2080)   File "/usr/local/lib/python3.12/dist-packages/vllm/v1/engine/utils.py", line 1240, in launch_core_engines
(APIServer pid=2080)     wait_for_engine_startup(
(APIServer pid=2080)   File "/usr/local/lib/python3.12/dist-packages/vllm/v1/engine/utils.py", line 1320, in wait_for_engine_startup
(APIServer pid=2080)     raise RuntimeError(
(APIServer pid=2080) RuntimeError: Engine core initialization failed. See root cause above. Failed core proc(s): {}
SERVE_EXIT_RC=1 2026-09-23T07:44:00Z
```

</details>

## Rung 5

NOT RUN. Rung 4 never reached "listening" in any exposure. No `Application startup complete`
line appears in the logs: the step-4 poll loop greps for it and for `SERVE_EXIT_RC=`, and only
`SERVE_EXIT_RC=1` matched, in all three logs.

## NVML calls observed

Sources: the mock's `MOCK_NVML_DEBUG` stderr (`c-nvml-summary.sh` over `r2-*.err`, `r3-*.err`,
`r4-*.log`), and `LD_DEBUG=bindings` for the complete list of NVML entry points resolved
(rung 2). Following the chief's correction, `MOCK_NVML_DEBUG` is the primary per-call trace, and it
carries the returned values. The engine-level `debugLog` covers the device getters (GetName,
GetMemoryInfo, GetCudaComputeCapability, GetP2PStatus, ...). It does not cover device count,
system-level getters or plain nvmlInit/nvmlShutdown. `LD_DEBUG=bindings` is the symbol-level
cross-check for those.

Positive control for the bindings trace: `nvmlDeviceGetCount_v2`, a call the debug log never prints,
appears in the bindings list of all three exposures
(`grep -h nvmlDeviceGetCount_v2 r2-*.nvml-bindings.txt` -> `1`, `10`, `1`). The same lists contain no
`nvmlSystem*` symbol (`grep -h -c nvmlSystem r2-*.nvml-bindings.txt` -> `0`, `0`, `0`), so vLLM
resolved no system-level NVML getter during discovery.

Entry points vLLM resolved in the mock `libnvidia-ml.so.1` during full discovery ((c) COMPAT, rung 2 probe):

| NVML function | Called by (vLLM v0.30.0) | Mock returned (debug line) |
|---|---|---|
| `nvmlInit` / `nvmlInitWithFlags` | `cuda_platform_plugin`, `with_nvml_context`, `cuda.py:1068`; torch's NVML device count | SUCCESS (`[ENGINE] Initialized with 4 devices (4 visible)`) |
| `nvmlShutdown` | same | SUCCESS (`[ENGINE] Shutdown complete`) |
| `nvmlDeviceGetCount_v2` | `cuda_platform_plugin`, `log_warnings`, torch `_device_count_nvml` | 4 (vLLM `device_count() -> 4`; no dedicated debug line) |
| `nvmlDeviceGetHandleByIndex_v2` | every per-device query | `ret=0` for 0..3 |
| `nvmlDeviceGetName` | `get_device_name`, `log_warnings` | `NVIDIA Graphics Device` |
| `nvmlDeviceGetCudaComputeCapability` | `get_device_capability` (API server and EngineCore) | `10.7` |
| `nvmlDeviceGetMemoryInfo` (v1) | `get_device_total_memory` (API server) | `total=309237645312 used=0` |
| `nvmlDeviceGetUUID` | `get_device_uuid` | `GPU-307f0000-0000-0000-0000-000000000000` |
| `nvmlDeviceGetP2PStatus` (NVLINK index) | `is_fully_connected` | `OK (nvlink)` for all 6 pairs |
| `nvmlDeviceGetNumaNodeId` | `get_device_numa_node` | `0` (GPU 0,1), `1` (GPU 2,3) |
| `nvmlDeviceGetCpuAffinity` | `_get_device_cpu_affinity` | `[18446744073709551615]` (3 calls) and `[0]` (2 calls) |
| `nvmlDeviceGetPciInfo_v3` | `get_all_gpu_pci_bus_ids` | `0002:81:00.0`, `0002:C1:00.0`, `000A:81:00.0`, `000A:E1:00.0` |

In (a) and (b), and in rung 3, only `nvmlInitWithFlags`, `nvmlDeviceGetCount_v2` and `nvmlShutdown`
were resolved before the process died. `vllm serve` in (c) exercised a subset of the table:
Init/Shutdown, GetHandleByIndex, GetName (log_warnings), GetCudaComputeCapability (API server once,
EngineCore twice) and GetMemoryInfo.

No NVML call failed. Across every captured log, the mock emitted no stub, NOT_SUPPORTED,
FUNCTION_NOT_FOUND, declined or non-zero-ret line. The same grep finds the `ret=0` lines, as a
positive control:

```
$ grep -h -c -E 'NVML-STUB|NOT_SUPPORTED|FUNCTION_NOT_FOUND|NOT IMPLEMENTED|declined|ret=[1-9]|MOCK_NVML WARNING' r2-*.err r3-*.err r4-*.log c-step1.log | paste -sd+ - | bc
0
$ grep -h -c -E 'ret=0' r2-*.err r3-*.err r4-*.log c-step1.log | paste -sd+ - | bc
76
```

Every process loaded the vr200 profile, not a fallback. Each process logs
`[CONFIG] Loaded YAML config: 4 devices, driver 615.23`, and the names are `NVIDIA Graphics Device`.

## Where the line is

Mokka's NVML covers everything vLLM v0.30.0 asks of NVML. The first thing Mokka cannot
provide is a `libcuda.so.1` that the vLLM wheel's own compiled extension can link against.
`vllm/platforms/cuda.py:23` imports `vllm._C_stable_libtorch` unguarded, and that `.so` has
`DT_NEEDED libcuda.so.1` with undefined driver symbols `cuGetProcAddress_v2`,
`cuPointerGetAttribute` and `cuTensorMapEncodeTiled`. `import vllm` resolves `current_platform`
on the way (`torch_utils.py:75`), so the whole `vllm` package, including `vllm serve` and
`vllm serve --help`, fails to import:

- With Mokka's CUDA shim on the path (15 exports, `cuInit` the only driver-API symbol) the failure
  is `undefined symbol: cuPointerGetAttribute`.
- Without it, the failure is `libcuda.so.1: cannot open shared object file`.

At that point vLLM has already asked NVML and been told "4 GPUs, CUDA platform"
(`Confirmed CUDA platform is available`). None of its per-device discovery has run yet.

With the image's own real CUDA 13 forward-compat `libcuda` on the path instead (exposure (c), not
part of Mokka), the unmodified vLLM discovery layer runs entirely on Mokka's NVML. It creates no
CUDA context, and it believes it has 4 x 288 GiB SM 10.7 GPUs, fully NVLink-connected, with FP8,
NVFP4 (CUTLASS), DeepGEMM and TRT-LLM attention supported and FlashInfer selected. `vllm serve` then
resolves the full engine config from those values (for example `max_num_batched_tokens=16384`),
downloads the config and tokenizer, and starts the EngineCore. The EngineCore's first CUDA runtime call,
`torch.accelerator.set_device_index(cuda:0)` at `gpu_worker.py:424`, fails with
`RuntimeError: No CUDA GPUs are available` (`cuInit` -> 100, CUDA_ERROR_NO_DEVICE).

Plain torch (rung 3) fails the same way in every exposure: `is_available() False`,
`device_count() 4` (NVML-backed), and allocation raises either `Found no NVIDIA driver` (Mokka shim,
or no libcuda) or `No CUDA GPUs are available` (compat libcuda).

## Prediction vs measurement (task B section 5.1)

| # | Task B predicted | Measured | Verdict |
|---|---|---|---|
| 1 | NVML answers every discovery call; `max_num_batched_tokens=16384` fingerprints vr200; no "Detected different devices", no dtype fallback, no "0 active driver(s)" | All true, but only under (c) COMPAT. In (a)/(b) the process dies before that log line. No failing NVML return anywhere; the vr200 profile loaded in every process | CONFIRMED (conditional on (c)) |
| 2 | `vllm._C_stable_libtorch` load fails, but it is NON-fatal: "vLLM swallows it (`cuda.py:239-244`)", with a WARNING `Failed to import from vllm._C_stable_libtorch` | FATAL. The unguarded top-level import at `cuda.py:23` runs first, during `import vllm`, and kills the process. No such WARNING line appears: `grep -l 'Failed to import from vllm._C_stable_libtorch' r2-*.out r2-*.err r4-*.log` -> rc=1, while `grep -c ImportError` on `r2-FULL.err`, `r4-FULL.log` and `r4-NVONLY.log` returns 1 each | WRONG on fatality |
| 2a | NRI/shim mode text: `undefined symbol: cu...`, "most likely `cuGetProcAddress_v2`" (INFERENCE) | `undefined symbol: cuPointerGetAttribute` | WRONG symbol, right class |
| 2b | CDI/no-libcuda text: `libcuda.so.1: cannot open shared object file: No such file or directory` | Exactly that, in (b) | CONFIRMED |
| 2c | "If instead the import succeeds, some real libcuda.so.1 (for example a CUDA forward-compat copy) is on the loader path, and step 3 fails with a different code" | Exactly (c): compat libcuda, import succeeds, step 3 fails with `No CUDA GPUs are available` | CONFIRMED |
| 3 | First fatal: EngineCore `gpu_worker.py:424 torch.accelerator.set_device_index(cuda:0)` -> `Found no NVIDIA driver on your system...`, then `Engine core initialization failed. See root cause above. Failed core proc(s): ...` | With the Mokka shim or no libcuda, the first fatal error is at `import vllm` in the API server (step 2). With compat libcuda the site is exactly `gpu_worker.py:424`, but the text is `No CUDA GPUs are available`. The API server line matches (`Failed core proc(s): {}`). Plain torch with the Mokka shim (rung 3a) gives B's predicted `Found no NVIDIA driver` text | Site CONFIRMED under (c); text differs; never reached under (a)/(b) |
| 4 | Not reached: NCCL init, MemorySnapshot, weight load; attention would pick FLASHINFER first for major 10 | Not reached in serve. The probe confirms FLASHINFER at priority 0 of 4 valid backends (`get_attn_backend_cls -> FlashInferBackend`) | CONFIRMED |

### The chief's relay of B's predictions (a)-(e)

| Prediction | Verdict | Evidence |
|---|---|---|
| (a) `import vllm` sets `PYTORCH_NVML_BASED_CUDA_CHECK=1`, so `torch.cuda.is_available()` is NVML-backed and vLLM believes in the 4 GPUs | CONFIRMED in (c); REFUTED in (a) FULL and (b) NVML-ONLY, where the variable is never set, because the import dies at `env_override.py:153`, before line 164 | `c-r2a-nvmlcheck.py`, `c-out/r2a-*.out`. FULL: `IMPORT_VLLM_FAILED ImportError ...undefined symbol: cuPointerGetAttribute` / `AFTER PYTORCH_NVML_BASED_CUDA_CHECK = None` / `torch.cuda.is_available() False` / `torch.cuda.device_count() 4`. NVML-ONLY: `IMPORT_VLLM_FAILED ImportError libcuda.so.1: cannot open shared object file` / `AFTER ... = None` / `is_available() False` / `device_count() 4`. COMPAT: `IMPORT_VLLM_OK` / `AFTER PYTORCH_NVML_BASED_CUDA_CHECK = 1` / `torch.cuda.is_available() True` / `torch.cuda.device_count() 4` / `torch.accelerator.device_count() 4` / `torch.cuda.is_initialized() False` |
| (b) API server logs `Chunked prefill is enabled with max_num_batched_tokens=16384` when vr200 memory was read | CONFIRMED in (c); not reached in (a)/(b) | `(APIServer pid=2080) INFO 09-23 07:43:35 [scheduler.py:288] Chunked prefill is enabled with max_num_batched_tokens=16384.`, preceded by the mock line `[NVML] nvmlDeviceGetMemoryInfo -> total=309237645312 used=0` (`r4-COMPAT.log`) |
| (c) Non-fatal warning `Failed to import from vllm._C_stable_libtorch` | REFUTED | The failure is fatal at `cuda.py:23` (unguarded) during `import vllm`. `grep -l 'Failed to import from vllm._C_stable_libtorch' r2-*.out r2-*.err r4-*.log` -> rc=1 (none); the same logs contain the fatal `ImportError` |
| (d) Fatal at `gpu_worker.py:424 torch.accelerator.set_device_index` with `RuntimeError: Found no NVIDIA driver on your system...`, then `Engine core initialization failed` | REFUTED for (a)/(b): vLLM dies at `import vllm` and never reaches the worker. PARTLY CONFIRMED for (c): same site and same API-server line, different text (`No CUDA GPUs are available`). B's exact text does occur with the Mokka shim, in plain torch (rung 3a) | `r4-FULL.log`, `r4-NVONLY.log`, `r4-COMPAT.log`; `r3-FULL.out` |
| (e) Risk: EngineCore is forked after the Go-based libnvidia-ml loaded, and may hang with no traceback | REFUTED (no hang). EngineCore was forked (default method; no spawn override), made NVML calls after the fork, and failed with a full traceback 2 s after it started. No retry with `spawn` was needed | `VLLM_WORKER_MULTIPROC_METHOD None` in the pod (`r2a-*.out`); `envs.py:930-931` default `"fork"`; `grep -c -i -E 'spawn\|fork' r4-COMPAT.log` -> 0, so the `We must use the spawn multiprocessing start method` override warning (`system_utils.py:157-160`) never fired; EngineCore lines `[NVML] nvmlDeviceGetCudaComputeCapability -> 10.7` (x2) between `07:43:53 Initializing a V1 LLM engine` and `07:43:55 EngineCore failed to start` |

Rung 1 identity check, requested by the chief: the pod saw vr200, not the A100 fallback.
It showed `NVIDIA Graphics Device, 294912 MiB, 10.7, 615.23` x4, and every process logged
`[CONFIG] Loaded YAML config: 4 devices, driver 615.23`.

## Anomalies and concerns

1. `python3 -m vllm.collect_env` in FULL got past `import vllm` twice in 10 runs, both times right
   after an `LD_DEBUG=bindings` probe run, and failed later at `torch.cuda.init()` with
   `Found no NVIDIA driver`. The other 8 runs, including one more repeat of that exact sequence,
   failed at `import vllm`. I could not explain it. `import vllm` and `vllm serve` never passed in
   FULL (every attempt is in the logs). This does not change any rung result.
2. Exposure (c) goes beyond the LADDER. It is the only way to exercise vLLM's discovery unmodified.
   It uses a library the image already ships (`/usr/local/cuda-13.0/compat`), with no change to vLLM or
   the image. Treat (c) results as "what vLLM would do if Mokka's `libcuda.so.1` exported the driver
   symbols the extension links against". That is INFERENCE for Mokka itself: (c) shows vLLM works
   with a complete symbol table, and it has not been tested with a Mokka shim that stubs those symbols.
3. NUMA discovery returns `None` because the Docker Desktop VM kernel has no
   `/sys/devices/system/node`. This limits the environment, not Mokka.
4. The image's `TORCH_CUDA_ARCH_LIST` is `8.0 8.7 8.9 9.0 10.0 11.0 12.0`, and vLLM's capability
   gates treat 10.7 as the 10.x family. Whether its prebuilt kernels would load on a real SM 10.7
   part is not something this spike can measure.
5. I deleted the ladder pod, as the chief asked, at 2026-09-23T07:52:49Z:
   `kubectl --context kind-mokka-vr200-llm -n spike-vllm delete pod vllm-ladder --wait=true` ->
   `pod "vllm-ladder" deleted from spike-vllm namespace`, `delete_rc=0`, then
   `get pods` -> `No resources found in spike-vllm namespace.` The scratch files remain
   (`/tmp/vr200-llm-spike-58fc971e/c-*`, `c-out/`, and the vLLM source clone `c-vllm-src/`). No
   tracked repo file was edited, and nothing was committed, pushed or posted.
6. MLA backend choice cannot be evaluated without a GPU. The CUTLASS_MLA backend module touches CUDA
   when it is imported (rung 2, extended). For DeepSeek-style models, attention selection itself
   would stop there even if everything else resolved.
