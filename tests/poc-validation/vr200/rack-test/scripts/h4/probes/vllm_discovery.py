# What vLLM's own code concludes about the hardware, WITHOUT creating a CUDA
# context. Every value comes from Mokka's NVML (vr200 profile). Each line is
# "RESULT key=value" so run.sh can check it.
import torch
import vllm
from vllm.platforms import current_platform as p


def result(key, fn):
    try:
        value = fn()
    except BaseException as e:  # show the failure instead of hiding it
        value = f"ERROR {type(e).__name__}: {str(e)[:200]}"
    print(f"RESULT {key}={value}", flush=True)


def nvfp4():
    from vllm.model_executor.layers.quantization.utils import nvfp4_utils
    return nvfp4_utils.cutlass_fp4_supported()


def deep_gemm():
    from vllm.utils.deep_gemm import is_deep_gemm_supported
    return is_deep_gemm_supported()


def trtllm_attention():
    from vllm.utils import flashinfer
    return flashinfer.supports_trtllm_attention(is_prefill=True)


result("vllm_version", lambda: vllm.__version__)
result("platform", lambda: type(p).__name__)
result("device_name_0", lambda: p.get_device_name(0))
result("compute_capability_0", lambda: "%d.%d" % tuple(p.get_device_capability(0)))
result("total_memory_bytes_0", lambda: p.get_device_total_memory(0))
# H4: a DRA claim of one GPU leaves one device visible, so [0, 1, 2, 3] would
# index past the end. Check every visible device instead; with one device the
# pair set is empty and the answer is vacuously True.
def visible_count():
    import pynvml
    pynvml.nvmlInit()
    return pynvml.nvmlDeviceGetCount()


result("nvml_visible_device_count", visible_count)
result("nvlink_fully_connected_visible",
       lambda: p.is_fully_connected(list(range(visible_count()))))
result("fp8_supported", lambda: p.supports_fp8())
result("nvfp4_cutlass_supported", nvfp4)
result("deep_gemm_supported", deep_gemm)
result("trtllm_attention_supported", trtllm_attention)
result("cuda_context_created", lambda: torch.cuda.is_initialized())
