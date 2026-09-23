# Task F report: how small can a libcuda.so.1 mock be for vLLM and SGLang on Mokka vr200?

Status: CANCELLED by user after F2 (F3 not run)

Completed before cancellation: F1 static census (both images) and F2 prototype mock + positive
control against the real libcudart.so.13. Namespace spike-libcuda deleted; no containers left running.

- Cluster / context: mokka-vr200-llm / kind-mokka-vr200-llm, namespace `spike-libcuda`
- Scratch dir: `/tmp/vr200-llm-spike-58fc971e/f-libcuda/`
- Engine images (cached on their nodes at run time):
  `docker.io/vllm/vllm-openai:v0.30.0` (worker, imageID 91d9b077589e7),
  `docker.io/lmsysorg/sglang:v0.5.20` (worker2, imageID 3ec36384d5ead)
- CUDA headers/runtime for F2 came from NVIDIA's PyPI wheels, not the images (the mock is
  built on the host, the images were still being read by tasks C/D):
  `nvidia-cuda-runtime 13.0.96` (`cuda.h` says `#define CUDA_VERSION 13000`, ships
  `libcudart.so.13`) + `nvidia-cuda-crt 13.0.88` (for `crt/host_defines.h`). SHAs in
  `wheels/`. The engines build on CUDA 13.0.2/13.0.3, so this is the matching runtime major.

## Headline

A small libcuda.so.1 mock is **necessary but not sufficient** to get either engine's torch
stack past CUDA init on Mokka. I built a throwaway mock that exports **699** `cu*` symbols
(everything either engine's ELF objects link, plus `cuGetProcAddress`/`_v2`), gives **223**
of them **real vr200 semantics**, and serves the whole driver-API surface `libcudart.so.13`
requests. Against the **real** `libcudart.so.13` it drives full device enumeration with
correct vr200 values (4 devices, "NVIDIA Graphics Device", cc 10.7, 288 GiB, 224 SMs,
driver 13040) - but `cudaGetDeviceCount()` still returns `cudaErrorNotSupported (801)`,
because the CUDA 13 runtime binds to the **private, undocumented `cuGetExportTable`
interface** and rejects the device when the export-table functions do not return real data.
So the floor is not the public driver API (that part is small and I built it); the floor is
an internal driver<->runtime ABI that a mock cannot reproduce without reverse-engineering
NVIDIA's private tables. This matches Mokka's own measurement in `docs/cuda-mock.md`
("CUDA driver version is insufficient") and task B's prediction that both engines die at/after
torch CUDA init.

## 1. Census numbers

| Engine | Static direct-link union (undefined `cu*`) | of which real libcuda syms | libcudart.so.13 upper bound (`cu*` in string table) | Actually-called (trace) |
|---|---|---|---|---|
| vLLM v0.30.0 | 119 | 106 (13 are `cuFile*` = libcufile, not libcuda) | 482 | see F2/F3 (positive control: 24 driver entry points before the export-table wall) |
| SGLang v0.5.20 | 119 | 106 (same 13 `cuFile*`) | 482 (same libcudart) | PENDING (F3) |

Both engines ship the **same** torch (`2.13.0+cu130`) and the same `libcudart.so.13`, so the
picture is the same: 119 undefined `cu*` in the union, 13 of them `cuFile*` (libcufile), 106
real libcuda symbols, **all 106 exported by the mock**. The two unions are not byte-identical
(SGLang additionally links the newer **green-context** and **multicast** driver symbols -
`cuGreenCtxCreate/Destroy/GetDevResource`, `cuCtxFromGreenCtx`, `cuDevResourceGenerateDesc`,
`cuDevSmResourceSplitByCount`, `cuMulticast*`; vLLM instead links some `cuMemcpy2D_v2`/
`cuStreamGetCtx`/etc.), but every one of those is present in `cuda.h` and therefore exported
by the mock (as a logging stub). SGLang: 3443 ELF `.so` scanned, **946** with `DT_NEEDED
libcuda.so.1`; site-packages `/opt/sglang/lib/python3.12/site-packages`.

Notes:
- "Static direct-link union" = every `UND` symbol matching `^cu[A-Z]` across all ELF `.so`
  under python site-packages + the CUDA/nvidia lib dirs, deduplicated. Method: `readelf -W
  --dyn-syms` per `.so` (the image ships readelf), run inside a pod of that image.
- vLLM: 2638 ELF `.so` scanned; **952** of them carry `DT_NEEDED libcuda.so.1`. The 13
  unexported symbols are all `cuFile*` (GPUDirect Storage), which libcufile.so provides, not
  the driver - so the mock covers **every** real libcuda symbol vLLM links (106/106).
- The libcudart upper bound (482) is the set of `cu*` names present in `libcudart.so.13`'s
  string table, i.e. the most it could ever ask the driver for via `cuGetProcAddress`. It has
  **no** `DT_NEEDED libcuda` and **no** undefined `cu*` symbols: it dlopens libcuda and binds
  every driver function dynamically. That is why exporting `cuGetProcAddress(_v2)` + `cuInit`
  is enough for it to *start* binding.

## 2. F1 demand census (static), detail

### vLLM: the union of 119 undefined `cu*` symbols
Run: `readelf -W --dyn-syms <each .so> | awk '$7=="UND" && $8 ~ /^cu[A-Z]/'`, deduplicated,
inside `spike-libcuda/f-census-vllm` (a `sleep` pod of the vLLM image on the vllm node,
memory limit 2Gi, no GPU requested, deleted after). Full list in `vllm-union.txt`; per-`.so`
lists in `vllm-per_so.txt`. The driver symbols actually referenced by name by the compiled
extensions (not resolved through cudart) are few:

```
vllm/_C_stable_libtorch.abi3.so (3):  cuGetProcAddress_v2 cuPointerGetAttribute cuTensorMapEncodeTiled
torch/lib/libcaffe2_nvrtc.so   (23):  cuCtxGetCurrent cuCtxSetCurrent cuDeviceGet cuDeviceGetAttribute
                                      cuDevicePrimaryCtxGetState cuDevicePrimaryCtxRetain cuFuncGetAttribute
                                      cuFuncSetAttribute cuFuncSetCacheConfig cuGetErrorString
                                      cuLaunchCooperativeKernel cuLaunchKernel cuLinkAddData_v2 cuLinkComplete
                                      cuLinkCreate_v2 cuModuleGetFunction cuModuleLoad cuModuleLoadData
                                      cuModuleLoadDataEx cuModuleUnload cuOccupancyMaxActiveBlocksPerMultiprocessor
                                      cuPointerGetAttribute cuTensorMapEncodeTiled
torch/lib/libtorch_python.so   (6):   cuFile*  (libcufile, not the driver)
```
`libtorch_cuda.so` / `libc10_cuda.so` are present but have **zero** undefined `cu*`: torch
reaches the driver through libcudart (dlopen + `cuGetProcAddress`), not by direct linkage.
This is the key structural fact - it is why the CUDA runtime, not the raw symbol set, is the
gate.

### SGLang: the union of 119 undefined `cu*` symbols
Same method, pod `spike-libcuda/f-census-sglang` on the sglang node (2Gi limit, no GPU,
deleted after). Full list in `sglang-union.txt`; per-`.so` in `sglang-per_so.txt`. As above,
the only unexported symbols are the 13 `cuFile*`. The driver symbols referenced directly by
name are again concentrated in a handful of extensions - flashinfer's JIT-cache `.so` files
reference `cuTensorMapEncodeTiled`, `cuLaunchKernelEx`, `cuModule*`, `cuLibrary*`, `cuFunc
SetAttribute`, `cuGetErrorString/Name`, `cuOccupancyMaxActiveClusters` (all exported, all with
real semantics or a benign stub); torch's `libcaffe2_nvrtc.so` links the same 23 as under
vLLM. `libtorch_cuda.so`/`libc10_cuda.so` again have zero direct undefined `cu*` - the runtime
is the gate.

## 3. F2 prototype

Built in `golang:1.26.8` (Debian 13, gcc 14, aarch64) - a plain linux/arm64 container with
gcc, matching the engines' arch. `build.sh` compiles `src/mock.c` against the wheel's
`cuda.h` (with `-D__CUDA_API_VERSION_INTERNAL` so every versioned entry point is declared),
generates the stub+dispatch tables from the header with `src/gen.py`, and links
`libcuda.so.1` with a `cu*`-only export map. Max glibc symbol version required: `GLIBC_2.34`
(runs on the engines' newer glibc).

- Line count: `src/mock.c` **2208**, `src/gen.py` 105, `src/mock_gen.h` 18 (hand-written =
  2331); generated `build/gen.c` 2466.
- Exports: **699** `cu*` symbols (`nm -D`), = the whole `cuda.h` entry-point set at this
  version (629 base names) plus per-thread `_ptds/_ptsz` variants and the GL/EGL/VDPAU names
  the typedef headers imply. Every symbol in each engine's F1 union (minus `cuFile*`) is
  exported.
- Real semantics: **223** functions (`build/impl_names.txt`). The rest are logging stubs
  returning `CUDA_SUCCESS` (`MOCK_CUDA_UNKNOWN=error` flips to `CUDA_ERROR_NOT_SUPPORTED`).
- `cuGetProcAddress(_v2)` resolves any base name at the caller's `cudaVersion` to the right
  exported variant, honouring the per-thread-default-stream flag, and returns this library's
  own implementation for known names, a logging stub otherwise. It also honours the
  `symbolStatus` out-param (SUCCESS / SYMBOL_NOT_FOUND / VERSION_NOT_SUFFICIENT).
- Tracing: `MOCK_CUDA_TRACE=<file>` writes one `FIRST` line per first call of each symbol,
  every `cuGetProcAddress` name with the variant it resolved to, and a per-symbol `COUNT` at
  exit (atexit, plus an mmap'd counts file that survives `fork`/`_exit`). `pthread_atfork`
  re-opens the counters in the child, so a forked EngineCore is traced separately.

### Functions that needed real semantics (the 223), by group
Device/driver identity and topology (count, get, name, UUID/UUID_v2, TotalMem_v2, PCIBusId,
ByPCIBusId, **GetAttribute** as a ~90-entry vr200 table, P2PAttribute, CanAccessPeer,
DriverGetVersion=13040); primary context + context stack (Retain/Release/GetState/SetFlags/
Reset, Get/Set/Push/PopCurrent, GetDevice, GetId, flags, limits, cache config, priority
range, Synchronize); memory as a host-backed `mmap(MAP_NORESERVE)` arena per device so
`cuMemGetInfo` decrements from 288 GiB and copies are real (Alloc/Free/AllocManaged/
AllocPitch/AllocHost/HostAlloc/HostRegister/HostGetDevicePointer, the async pool variants,
the VMM set cuMemAddressReserve/Create/Map/SetAccess/Release, GetAddressRange, mem pools);
the full `cuMemcpy*` and `cuMemset*` families (every copy is a `memmove`, every large zero-set
is `madvise(MADV_DONTNEED)` so nothing touches real RAM until written); streams and events as
no-ops (events timestamp with the host monotonic clock, `cuEventElapsedTime` returns real ms);
module/library/kernel/function loading (accept the image, hand back handles, globals get a 1
MiB arena slice); `cuFuncGetAttribute`/occupancy queries; `cuGetErrorName/String`;
`cuPointerGetAttribute(s)`. Values marked ASSUMED in the source (not in `vr200.yaml`): SM
count 224, L2 128 MiB, shared-mem-per-SM 233472, and the sm_100-class attribute constants.

Iterations to build it: **2** compile fixes (a `_GNU_SOURCE`->`_DEFAULT_SOURCE` swap to avoid
a `GLIBC_2.38` C23 `sscanf/strtol` redirect that would not load on older glibc, and a buffer
size), then it linked and ran. The blocker below is **not** a mock defect - it is a property
of the CUDA runtime.

### 3.1 Positive control against the real `libcudart.so.13`

`src/pc.c`: links the wheel's real `libcudart.so.13`, calls `cudaDriverGetVersion`,
`cudaRuntimeGetVersion`, `cudaGetDeviceCount`, `cudaGetDeviceProperties`, `cudaGetDeviceP
CIBusId`, `cudaSetDevice`, `cudaMemGetInfo`, `cudaMalloc`, a `cudaMemcpy` round trip, a 200
GiB alloc+memset, `cudaFree`, `cudaDeviceSynchronize`. Run with the mock first on
`LD_LIBRARY_PATH` (`ldd` confirms `libcudart.so.13 => .../lib`, and cudart dlopens the mock
`libcuda.so.1`). Verbatim:

```
cudaDriverGetVersion(&dv)   -> 0 cudaSuccess
cudaRuntimeGetVersion(&rv)  -> 0 cudaSuccess
driver_version=13040 runtime_version=13000
cudaGetDeviceCount(&n)      -> 801 cudaErrorNotSupported
device_count=-1
... every subsequent call -> 801 cudaErrorNotSupported ...
RESULT FAIL (failed calls: 14)
```

The trace shows why. Two runs:

- **Export tables returned NOT_SUPPORTED (the honest default):** cudart resolves 24 driver
  entry points through `cuGetProcAddress_v2`, calls `cuInit`, `cuDriverGetVersion`, then asks
  `cuGetExportTable` for two private tables (`f8cff951...`, `6bd5fb6c...`), gets NOT_SUPPORTED,
  and **never enumerates a device** - `cudaGetDeviceCount` returns 801.
- **Export tables returned a stub table (`MOCK_CUDA_EXPORT=probe`, a diagnostic mode):**
  cudart now asks for a **third** table (`a094798c-...-0800200c0a66`), then does enumerate
  every device - `cuDeviceGetCount` (1), `cuDeviceGet` (4), `cuDeviceGetName` (4),
  `cuDeviceTotalMem_v2` (4), `cuDeviceGetUuid` (4), `cuDeviceGetAttribute` (**444** = 111
  attrs x 4 devices), all served with correct vr200 values - and calls **slot 1** of that
  third table once. Because my stub returns 0 without filling the output buffers,
  `cudaGetDeviceCount` **still** returns 801.

Decisive facts from the trace (`build/pc-it1.trace`, `build/pc-probe.trace`):
- Every `cu*` name cudart requested resolved to a **real implementation** - **no stub was
  ever called**, and **no** `cuGetProcAddress` returned VERSION_NOT_SUFFICIENT. The public
  driver-API surface is therefore complete for what cudart needs.
- The **only** thing standing between the mock and a working runtime is the private
  `cuGetExportTable` interface: cudart requires it to even attempt enumeration, and requires
  its functions to return real per-device data to accept the device. This ABI is undocumented
  and version-specific; reproducing it is out of scope for "a small libcuda mock" and was not
  attempted (proportionality: it would be a large reverse-engineering effort with no stable
  contract).

INFERENCE: this is exactly the wall torch hits. `torch.cuda` initialisation goes through
`libcudart` (task B: torch loads `libcudart.so.13`, reaches the driver via
`cuGetProcAddress_v2`, checks `cuDriverGetVersion`). vLLM's own compiled extensions that call
the **driver API directly** (`cuGetProcAddress`, `cuTensorMapEncodeTiled`, `cuPointerGet
Attribute` in `_C_stable_libtorch`) would bind fine against the mock - but the torch device
init that gates everything runs through cudart, so it stops here regardless of how complete
the raw symbol set is.

## 4. F3 engine runs (gated on the chief)

Not started - waiting for the chief's go-ahead per the brief, and flagging the F2 finding
first: because `libcudart.so.13` cannot initialise against a public-API-only libcuda mock,
`torch.cuda.is_available()`/`device_count()`-backed paths that use the runtime will fail at
init, and both engines are predicted (task B) to die at/after that point. F3 would still be a
useful *measurement* (it pins the exact error and message with the mock actually present, and
tests whether vLLM's NVML-based availability check advances further than SGLang's runtime-based
one), but it will not produce a serving engine. Awaiting the chief's decision on whether to
spend the F3 box on that measurement.

## 5. Non-libcuda blockers (from the census + control; more to come in F3)

- The **CUDA runtime's private export-table ABI** (section 3.1) - the first and hardest wall,
  and it sits *inside* libcudart, not in libcuda.
- Even past a hypothetical working runtime, task B/C already name the JIT/kernel blockers a
  libcuda mock cannot satisfy: Triton/`ptxas`, FlashInfer/`nvcc` refusing `sm_107`, cuBLAS/
  cuDNN, NCCL, and any code path that reads back a *computed* value (a real matmul result).
  The mock's kernels are no-ops, so numeric output would be meaningless even if it ran.
- `cuFile*` (GPUDirect Storage) is referenced by `libtorch_python.so` but provided by
  libcufile, not the driver; not a libcuda concern.

## 6. Verdict (one paragraph)

**Is a small libcuda mock all we need? No - and the reason is precise.** The public CUDA
driver API that a mock can export is genuinely small: ~630 entry points, of which only ~223
need real behaviour and only ~106 are even linked by name by vLLM's binaries, and I built
that in ~2300 lines with correct vr200 identity and a real host-backed memory arena. That
mock is enough to make the driver library *load and bind*, to satisfy the compiled extensions
that call the driver directly, and to answer every device-identity and memory-accounting
question with vr200 values. But it is **not** enough to bring up an engine, because the CUDA
13 **runtime** (`libcudart.so.13`, which torch and therefore both engines sit on) refuses to
initialise a device unless the driver also implements the private, undocumented
`cuGetExportTable` interface - a driver<->runtime ABI outside the public surface that a mock
cannot reproduce without reverse-engineering and that changes across CUDA versions. So a small
libcuda mock buys Mokka the **software-contract** layer around CUDA (driver present, version
13040, 4x vr200 devices discoverable through the driver API, 288 GiB accounted, PCI/UUID/
attribute reads, module/stream/event handles) - useful for exercising deployment, scheduling,
device-discovery and API-surface code paths - but it does **not** buy CUDA execution, and it
does not get torch/vLLM/SGLang past `torch.cuda` init. For "help framework developers with vLLM and SGLang"
that means: a libcuda mock is the wrong lever for anything downstream of runtime init (KV-cache
sizing from real `cudaMemGetInfo`, kernel launch, serving); those need either real GPUs or a
full CUDA-runtime emulation, which is a different and far larger effort than a libcuda shim.

## Files
- Mock source: `f-libcuda/src/mock.c`, `src/gen.py`, `src/mock_gen.h`, `src/et_tramp.h`;
  build `f-libcuda/build.sh` -> `build/libcuda.so.1`.
- Positive control: `f-libcuda/src/pc.c`, `pc.sh`; logs `build/pc-it1.log`, `build/pc-probe.log`;
  traces `build/pc-it1.trace`, `build/pc-probe.trace`.
- Census: `f-census.sh`; `vllm-union.txt`, `vllm-per_so.txt`, `vllm-needed_libcuda.txt`,
  `build/libcudart_cu_upperbound.txt`, `build/mock_exports.txt`, `vllm-union-missing.txt`.
- CUDA headers/runtime: `f-libcuda/cudart13/` (from the two NVIDIA wheels in `wheels/`).

No tracked repo files were edited; nothing was committed or pushed.
