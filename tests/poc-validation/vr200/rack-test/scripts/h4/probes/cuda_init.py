# The exact CUDA error the pod gets, first from the driver API directly, then
# from torch. cuInit and cudaGetDeviceCount create no context. Each line is
# "RESULT key=value". cuinit_rc=0 means a real kernel module accepted this
# libcuda: the run script then skips `vllm serve`, which would create a context.
import ctypes
import warnings


def maps(sub):
    with open("/proc/self/maps") as f:
        return sorted({l.split()[-1] for l in f if sub in l and "/" in l})


cuda = ctypes.CDLL("libcuda.so.1")
print("RESULT libcuda_loaded=%s" % maps("libcuda"), flush=True)


def err(rc):
    name, text = ctypes.c_char_p(), ctypes.c_char_p()
    cuda.cuGetErrorName(rc, ctypes.byref(name))
    cuda.cuGetErrorString(rc, ctypes.byref(text))
    return "%s (%s)" % ((name.value or b"?").decode(), (text.value or b"?").decode())


ver = ctypes.c_int(0)
cuda.cuDriverGetVersion(ctypes.byref(ver))
print("RESULT libcuda_driver_version=%d" % ver.value, flush=True)
rc = cuda.cuInit(0)
print("RESULT cuinit_rc=%d %s" % (rc, err(rc)), flush=True)
count = ctypes.c_int(-1)
rc2 = cuda.cuDeviceGetCount(ctypes.byref(count))
print("RESULT cudevicegetcount_rc=%d %s count=%d" % (rc2, err(rc2), count.value), flush=True)
if rc == 0:
    # A real kernel module answered. Stop before torch, which may go further.
    print("RESULT safety_stop=cuInit succeeded, skipping torch", flush=True)
    raise SystemExit(0)

import torch  # noqa: E402

with warnings.catch_warnings(record=True) as caught:
    warnings.simplefilter("always")
    available = torch.cuda.is_available()
    n = torch.cuda.device_count()
print("RESULT torch_cuda_available=%s torch_device_count=%d" % (available, n), flush=True)
for w in caught:
    print("RESULT torch_warning=%s" % str(w.message).replace("\n", " ")[:400], flush=True)
try:
    torch.cuda.init()
    print("RESULT torch_cuda_init=ok", flush=True)
except BaseException as e:
    print("RESULT torch_cuda_init_error=%s: %s" % (type(e).__name__, str(e).replace("\n", " ")[:400]),
          flush=True)
print("RESULT torch_cuda_initialized=%s" % torch.cuda.is_initialized(), flush=True)
