# vLLM and SGLang on a simulated Vera-Rubin cluster (Mokka vr200)

How far can the unmodified vLLM and SGLang images get on a Kubernetes cluster
that simulates Vera-Rubin (VR200) capacity, with no GPU anywhere? This bundle
answers that on a laptop with kind and Mokka's `vr200` profile
(NVIDIA/k8s-test-infra PR #872, not merged yet).

Short answer: everything above the CUDA driver works; nothing that runs on the
GPU does.

## What it shows

| Step | What runs | Result |
|---|---|---|
| `up` | kind, 1 control-plane + 3 workers; Mokka `vr200`; the NVIDIA device plugin | every worker advertises `nvidia.com/gpu: 4` |
| `vllm` | `vllm/vllm-openai:v0.30.0`, requesting 4 GPUs | vLLM's own code sees 4x Rubin: CUDA platform, compute capability 10.7, 288 GiB, full NVLink, FP8 / NVFP4 (CUTLASS) / DeepGEMM / TRT-LLM attention enabled. `vllm serve` resolves its config, then stops at the first CUDA context: `RuntimeError: No CUDA GPUs are available` |
| `sglang` | `lmsysorg/sglang:v0.5.20`, requesting 4 GPUs | SGLang's helpers read VR200 (294912 MiB), but SGLang checks for a GPU through the CUDA runtime, so `launch_server` stops while parsing arguments: `RuntimeError: No accelerator ... is available` |
| `vllm-serve` | `vllm/vllm-openai-cpu:v0.30.0` as a Deployment + Service requesting 4 GPUs | the pod sees 4 VR200 GPUs in `nvidia-smi` and answers `/v1/completions` through the Service, with Prometheus metrics. Tokens are computed on CPU |

Each step checks the values above and exits non-zero if one does not hold.

## What it does not show

Loading a model onto a GPU, running kernels, multi-GPU (NCCL, tensor
parallelism), CUDA graphs, or any performance number. Mokka simulates the
software contracts around NVIDIA GPUs (NVML, `nvidia-smi`, device plugin, DRA,
DCGM), not CUDA execution. Getting an engine past CUDA init would need a CUDA
driver simulation, which Mokka does not have.

SGLang's CPU build is x86 only (Intel Xeon), so there is no SGLang serving step
on an arm64 Mac.

## Run it

Needs Docker, kind, kubectl, Helm 3.8+, about 30 GB of free disk for images, and
a checkout of PR #872 (for the `vr200` profile and the chart).

```bash
export MOKKA_SRC=/path/to/k8s-test-infra-at-pr-872   # default: the local spike worktree
./run.sh up          # cluster + Mokka vr200 + device plugin
./run.sh prepull     # optional: pull the ~25 GB of engine images up front
./run.sh vllm
./run.sh sglang
./run.sh vllm-serve  # first start downloads ~1 GB of weights (~7 min)
./run.sh clean       # remove the demo namespace
./run.sh down        # delete the cluster (and its cached images)
```

`CLUSTER` (default `mokka-vr200-llm`) picks the kind cluster; `up` reuses an
existing cluster and Mokka release.

## How the pods get the simulated driver

The device plugin allocates `/dev/nvidia*` nodes but, on a plain kind node
(runc, no NVIDIA container runtime, no CDI), puts no driver libraries in the
container. Each pod here mounts Mokka's driver root (`/var/lib/nvml-mock`) and
an init container copies only `libnvidia-ml.so*` into the library path, the way
a GPU node's container runtime would expose NVML.

For vLLM the image's own CUDA forward-compat `libcuda` goes on the library
path as well. Mokka's mock `libcuda` must not: vLLM's compiled extension links
`libcuda.so.1` and needs `cuPointerGetAttribute`, `cuTensorMapEncodeTiled` and
`cuGetProcAddress_v2`, which the mock lacks, so `import vllm` would fail.

## Deployment details learned on the way

- A Deployment whose pod takes all 4 GPUs needs `strategy: Recreate`; a rolling
  update waits forever for GPUs the old pod still holds.
- Set `enableServiceLinks: false` on vLLM pods: a Service named `vllm` injects
  `VLLM_PORT=tcp://...`, which vLLM refuses.
- The vLLM CPU build with this 0.5B model needs more than a 4Gi limit with a
  1 GiB KV cache; the manifest uses a 256 MiB KV cache to fit 4Gi.
