# What SGLang's own helpers read from the hardware. Values come from Mokka's
# NVML / nvidia-smi (vr200 profile). Each line is "RESULT key=value".
import sglang
import torch
from sglang.srt.utils import common


def result(key, fn):
    try:
        value = fn()
    except BaseException as e:
        value = f"ERROR {type(e).__name__}: {str(e)[:200]}"
    print(f"RESULT {key}={value}", flush=True)


result("sglang_version", lambda: sglang.__version__)
result("nvgpu_memory_capacity_mib", lambda: common.get_nvgpu_memory_capacity())
# SGLang decides whether a GPU exists through the CUDA runtime, not NVML.
result("torch_cuda_is_available", lambda: torch.cuda.is_available())
