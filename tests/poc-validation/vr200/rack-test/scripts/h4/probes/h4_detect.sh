#!/bin/bash
# Runs inside the unmodified vllm/vllm-openai:v0.30.0 image in a pod that holds
# one DRA-allocated GPU. Phase A records what DRA/CDI put into the container
# with nothing of ours on any search path. Phase B is the spike's proven
# exposure: Mokka NVML only (copied into /opt/nvml-only by the init container)
# plus the image's own CUDA forward-compat libcuda.
set -u
echo "PHASE A: DRA/CDI injection alone (image env + CDI edits) $(date -u +%FT%TZ)"
echo "== A1 /dev/nvidia*"
ls -l /dev/nvidia* 2>&1
echo "== A2 env (nvidia|cuda|mock|ld_library)"
env | grep -iE 'nvidia|cuda|mock|ld_library' | sort
echo "== A3 ldconfig -p (libcuda|libnvidia-ml)"
ldconfig -p | grep -E 'libcuda\.so|libnvidia-ml\.so'
echo "== A4 find libnvidia-ml.so* / libcuda.so* (outside /proc, /sys and our own /opt/nvml-mock, /opt/nvml-only mounts)"
find / \( -path /proc -o -path /sys -o -path /opt/nvml-mock -o -path /opt/nvml-only \) -prune -o \
  \( -name 'libnvidia-ml.so*' -o -name 'libcuda.so*' \) -print 2>/dev/null | sort
echo "== A5 mountinfo (nvidia|nvml|cuda|cdi)"
grep -E 'nvidia|nvml|cuda|cdi' /proc/self/mountinfo | awk '{print $4, $5, $9}'
echo "== A6 nvidia-smi"
if command -v nvidia-smi >/dev/null 2>&1; then
  echo "nvidia-smi at $(command -v nvidia-smi)"
  nvidia-smi -L 2>&1; echo "nvidia-smi -L rc=$?"
  nvidia-smi --query-gpu=name,memory.total,compute_cap,driver_version,pci.bus_id --format=csv 2>&1
else
  echo "nvidia-smi not present"
fi
echo "== A7 NVML identity through default library resolution"
python3 /probes/nvml_identity.py 2>&1
echo "== A8 same, MOCK_NVML_DEBUG=1 (config source lines only)"
MOCK_NVML_DEBUG=1 python3 /probes/nvml_identity.py 2>&1 | grep -E '\[CONFIG\]|\[ENGINE\]|Failed|IDENTITY (driver|gpu)' | head -20
echo "== A9 the host kernel module as the pod sees it through /proc (read only)"
head -1 /proc/driver/nvidia/version 2>&1
ls /proc/driver/nvidia/gpus/ 2>&1
echo "== A10 open() and close() of each injected /dev/nvidia* (no ioctl, no CUDA)"
python3 -c '
import errno, glob, os
for p in sorted(glob.glob("/dev/nvidia*")):
    try:
        os.close(os.open(p, os.O_RDWR))
        print("OPEN %s ok" % p)
    except OSError as e:
        print("OPEN %s errno=%d %s (%s)" % (p, e.errno, errno.errorcode.get(e.errno), e.strerror))
' 2>&1
echo "== A11 does libcuda.so.1 resolve with DRA's injection alone (dlopen only, no cuInit)"
python3 -c '
import ctypes
try:
    ctypes.CDLL("libcuda.so.1")
    print("DLOPEN libcuda.so.1 ok: %s" % sorted({l.split()[-1] for l in open("/proc/self/maps") if "libcuda" in l}))
except OSError as e:
    print("DLOPEN libcuda.so.1 failed: %s" % e)
' 2>&1
ls -l /usr/lib64/libcuda* 2>&1

echo
echo "PHASE B: proven exposure (NVML only + image compat libcuda) $(date -u +%FT%TZ)"
export PATH=/opt/nvml-mock/driver/usr/bin:/usr/local/cuda/bin:/usr/local/nvidia/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LD_LIBRARY_PATH=/opt/nvml-only:/usr/local/cuda-13.0/compat:/usr/local/nvidia/lib64:/usr/local/cuda/lib64:/usr/local/nvidia/lib
export MOCK_NVML_CONFIG=/opt/nvml-mock/driver/config/config.yaml
echo "== B1 nvidia-smi"
nvidia-smi -L 2>&1
nvidia-smi --query-gpu=name,memory.total,compute_cap,driver_version,pci.bus_id --format=csv 2>&1
echo "== B2 NVML identity"
python3 /probes/nvml_identity.py 2>&1
echo "== B3 vLLM's own view of the hardware (no CUDA context)"
python3 /probes/vllm_discovery.py 2>&1 | grep -E '^RESULT|Error|error' | head -40
echo "== B4 CUDA init, exact error text"
python3 /probes/cuda_init.py > /tmp/cuda_init.log 2>&1
grep -E '^RESULT' /tmp/cuda_init.log
grep -vE '^RESULT' /tmp/cuda_init.log | tail -5
echo "== B5 vllm serve: how far it gets"
if grep -q '^RESULT cuinit_rc=0 ' /tmp/cuda_init.log; then
  echo "RESULT serve_skipped=cuInit succeeded against a real kernel module"
  exit 0
fi
python3 -c "import urllib.request; print('RESULT hf_reachable=%s' % urllib.request.urlopen('https://huggingface.co/api/models/Qwen/Qwen2.5-0.5B-Instruct', timeout=15).status)" 2>&1 | tail -1
timeout 300 vllm serve Qwen/Qwen2.5-0.5B-Instruct --enforce-eager \
  --max-model-len 2048 --port 8000 > /tmp/serve.log 2>&1
echo "RESULT serve_rc=$?"
echo "RESULT serve_config=$(grep -m1 -oE 'max_num_batched_tokens=[0-9]+' /tmp/serve.log)"
echo "RESULT serve_stop=$(grep -m1 -oE 'RuntimeError: .*' /tmp/serve.log)"
echo "RESULT serve_listening=$(grep -cE 'Uvicorn running|Application startup complete' /tmp/serve.log)"
echo "== B6 serve.log: error and CUDA lines"
grep -nE 'Error|error|CUDA|cuda|driver' /tmp/serve.log | grep -vE 'DeprecationWarning' | head -40
echo "== B7 serve.log tail"
tail -25 /tmp/serve.log
echo "END $(date -u +%FT%TZ)"
exit 0
