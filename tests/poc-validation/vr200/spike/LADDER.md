# The ladder (shared by the vLLM and SGLang wave-1 tasks)

Each engine's REAL CUDA image runs in one pod on its assigned vr200 node. You
climb rungs in order and record, for every rung, PASS / FAIL / PARTIAL with the
exact command and verbatim output. A FAIL does not stop you: keep climbing where
later rungs are still meaningful, and say which failures cascade.

## Pod shape

- Namespace and nodeSelector from your task brief (`spike.mokka/track=<track>`).
- `resources.limits: {nvidia.com/gpu: 4}`, `command: ["sleep","infinity"]`.
- Whatever the driver-injection mechanism needs, as documented in
  task-A-platform-report.md in this directory (read it first: it tells you HOW
  libnvidia-ml.so and nvidia-smi reach a container and at which paths). If an
  arbitrary image does NOT receive them automatically, make the minimal change
  that gets them there the way a real GPU node would (for example the
  device plugin's env/mount contract), and record exactly what you did. Do not
  bake anything into the engine image.
- Env `MOCK_NVML_DEBUG=1` on the pod so the mock NVML library logs every call
  the engine makes to stderr (bridge/helpers.go: debugLog writes to stderr when
  MOCK_NVML_DEBUG is set). Capture those lines for rungs 2 and 4: they are the
  dynamic list of NVML calls the engine really makes.
- Keep HF downloads inside the pod (`HF_HOME=/tmp/hf`). Model:
  Qwen/Qwen2.5-0.5B-Instruct.

## Rungs

1. Scheduled and GPUs visible: pod Running on the assigned node;
   `nvidia-smi -L`; `nvidia-smi --query-gpu=name,memory.total,compute_cap,driver_version --format=csv`.
2. The engine's OWN hardware-discovery code (task-specific commands in your
   brief). This is the rung that answers "could the framework use Mokka":
   what does the framework itself believe about the hardware?
3. torch CUDA init: `python3 -c "import torch; print(torch.__version__, torch.version.cuda); print('avail', torch.cuda.is_available()); print('count', torch.cuda.device_count()); x = torch.zeros(1, device='cuda'); print('alloc ok', x)"`.
   Also record which libcuda.so.1 the process loads (for example
   `ldconfig -p | grep libcuda`, and /proc/<pid>/maps of a python process that
   imported torch and touched CUDA, or `LD_DEBUG=libs` output filtered to
   libcuda) so we know whether it hit Mokka's CUDA shim, the image's own
   compat libcuda, or nothing.
4. Server start: the engine's standard serve command (in your brief), wrapped
   in the container's `timeout 900`, output to a file inside the pod, then
   copied out. Record the FIRST fatal error verbatim, the last ~80 lines of the
   log, and how far it got (platform detected, config resolved, model
   downloaded, weights loaded, KV cache profiled, server listening?).
5. Only if rung 4 reached "listening": POST /v1/completions from inside the pod
   and paste the response.

## Report skeleton

Header: Status (DONE / DONE_WITH_CONCERNS / BLOCKED / NEEDS_CONTEXT), image
digest actually pulled (`crictl inspecti` or `kubectl get pod -o jsonpath` on
imageID), engine version printed by the engine itself.

Then a table: | Rung | Result | Decisive evidence line |, followed by one
section per rung with the full command and output.

Then "NVML calls observed" (deduplicated list from MOCK_NVML_DEBUG, with the
return codes the mock gave) and "Where the line is": one paragraph, facts
only, naming the first thing Mokka could not provide.

If task-B-surface-report.md exists in this directory when you finish, add a
short "Prediction vs measurement" section comparing its PREDICTION for your
engine with what you observed.

## ADDENDUM (chief, after task A, 2026-09-23 ~06:00Z) - overrides anything above

1. Driver injection. The device-plugin setup does NOT inject libnvidia-ml.so,
   nvidia-smi or libcuda into pods (runc only, no CDI, no NRI; verified by
   task A). Build every engine pod from task A's tested template
   /tmp/vr200-llm-spike-58fc971e/a-gpu-pod-manual.yaml: hostPath
   /var/lib/nvml-mock mounted read-only at /opt/nvml-mock, and env
   PATH=/opt/nvml-mock/driver/usr/bin:<the image's own PATH>,
   LD_LIBRARY_PATH=/opt/nvml-mock/driver/usr/lib64:<the image's own LD_LIBRARY_PATH, if any>,
   MOCK_NVML_CONFIG=/opt/nvml-mock/driver/config/config.yaml, plus
   MOCK_NVML_DEBUG=1. Read the image's own PATH / LD_LIBRARY_PATH first
   (`crictl inspecti` on the node, or the image config) and APPEND them; do
   not drop the image's values. Use nodeSelector spike.mokka/track=<track>.
2. Two library exposures for rung 3 (and rung 4 if time allows). That lib64
   directory also holds the mock CUDA shim (libcuda.so.1, 15 exports) and a
   libcudart.so.12 -> libcuda.so.1 symlink that can SHADOW the engine's real
   CUDA runtime when it is found via LD_LIBRARY_PATH. Measure both:
   (a) FULL: LD_LIBRARY_PATH as in item 1 (NVML + CUDA shim).
   (b) NVML-ONLY: copy just libnvidia-ml.so* from /opt/nvml-mock/driver/usr/lib64
       into an emptyDir (e.g. /opt/nvml-only) and point LD_LIBRARY_PATH there
       instead, so the engine gets NVML but NO mock libcuda/libcudart.
   For each, record which libcuda.so.1 and libcudart the process actually
   loaded (LD_DEBUG=libs filtered to cuda, or /proc/<pid>/maps). Report (a)
   and (b) side by side. You can do this with two pods or by overriding env on
   `kubectl exec` (env VAR=... python3 ...).
3. Memory is tight: the Docker VM has ~4.7 GB available, swap is full, and
   several other kind clusters share it. Set `resources.limits.memory: 3Gi`
   and `requests.memory: 1Gi` on ladder pods (task E has its own limits). If
   a pod is OOMKilled, record it (kubectl describe: Last State OOMKilled), wait
   a few minutes, retry once, and report it. Never touch other clusters.
4. Image pulls are still in progress on your node (logs:
   /tmp/vr200-llm-spike-58fc971e/a-pull-<track>-<node>.log). While waiting,
   do all the source reading you can (verify API names from the pinned
   source, prepare scripts). Do not start a second pull of the same image.
