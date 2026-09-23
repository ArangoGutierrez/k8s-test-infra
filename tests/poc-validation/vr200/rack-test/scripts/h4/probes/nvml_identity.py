# Which NVML the process loads and what identity it reports. No CUDA.
# Each line is "IDENTITY ..." so the run script can grep it.
import os

import pynvml


def maps(sub):
    with open("/proc/self/maps") as f:
        return sorted({l.split()[-1] for l in f if sub in l and "/" in l})


print("IDENTITY MOCK_NVML_CONFIG=%s" % os.environ.get("MOCK_NVML_CONFIG"), flush=True)
print("IDENTITY LD_LIBRARY_PATH=%s" % os.environ.get("LD_LIBRARY_PATH"), flush=True)
try:
    pynvml.nvmlInit()
except BaseException as e:
    print("IDENTITY nvmlInit ERROR %s: %s" % (type(e).__name__, e), flush=True)
    raise SystemExit(0)
print("IDENTITY nvml_lib=%s" % maps("libnvidia-ml"), flush=True)
print("IDENTITY driver=%s count=%d" % (pynvml.nvmlSystemGetDriverVersion(),
                                       pynvml.nvmlDeviceGetCount()), flush=True)
for i in range(pynvml.nvmlDeviceGetCount()):
    h = pynvml.nvmlDeviceGetHandleByIndex(i)
    fields = {}
    for key, fn in (
        ("name", lambda: pynvml.nvmlDeviceGetName(h)),
        ("arch", lambda: pynvml.nvmlDeviceGetArchitecture(h)),
        ("cc", lambda: "%d.%d" % pynvml.nvmlDeviceGetCudaComputeCapability(h)),
        ("mem", lambda: pynvml.nvmlDeviceGetMemoryInfo(h).total),
        ("minor", lambda: pynvml.nvmlDeviceGetMinorNumber(h)),
        ("uuid", lambda: pynvml.nvmlDeviceGetUUID(h)),
        ("pci", lambda: pynvml.nvmlDeviceGetPciInfo(h).busId),
    ):
        try:
            fields[key] = fn()
        except BaseException as e:
            fields[key] = "ERROR %s" % type(e).__name__
    print("IDENTITY gpu%d %s" % (i, " ".join("%s=%s" % kv for kv in fields.items())),
          flush=True)
