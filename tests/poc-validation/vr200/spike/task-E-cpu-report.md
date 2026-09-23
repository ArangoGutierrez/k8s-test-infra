# Task E report: CPU-backend serving control on a Mokka vr200 node

Status: DONE_WITH_CONCERNS

Lane: namespace `spike-cpu`, node `mokka-vr200-llm-worker3` (`spike.mokka/track=cpu`),
context `kind-mokka-vr200-llm`. Scratch: `/tmp/vr200-llm-spike-58fc971e/cpu/`.

## Summary

**E1: yes.** The standard serving shape runs end to end on a Mokka vr200 node, with tokens
computed on CPU. The shape is a Deployment + Service with `nvidia.com/gpu: 4`, a `/health`
readiness probe, the OpenAI API, and Prometheus `/metrics`. One pod
(`vllm-cpu-b4cbd5f5d-ndv7j`) holds all 4 simulated GPUs, shows 4 "NVIDIA Graphics
Device" 294912 MiB cc 10.7 GPUs in `nvidia-smi`, and answers `/v1/completions` with
HTTP 200 through the Service. The cluster is not broken.

- **Platform detection:** vLLM's CPU build loads the mock NVML in all three serving
  processes and counts 4 GPUs. It still selects the CPU platform (`device_config=cpu`)
  because its version is `0.30.0+cpu` and the CUDA plugin checks for that substring. No
  override was needed.
- **Timing:** creation to Ready took 8m01s, of which 410 s was the HF weight download.
  Engine init took 0.96 s. A 16-token completion took 3.8-7.1 s (1.99 s once E2 was gone).
- **Findings for the guide**, each with evidence below:
  1. At 4Gi the addendum's KV 1 GiB OOMKills every time, with or without a smaller
     max-model-len. The kernel OOM record gives the split (worker 2.82 GB = 0.75 base +
     0.99 weights + 1.07 KV; API server 0.86 GB; engine core 0.46 GB). Lowering
     max-model-len alone cannot fix it on CPU. It worked with `--kv-cache-memory-bytes`
     at 256 MiB, which **deviates from the addendum**. I told main first. Peak is 4.08 of
     4.29 GB. Use 5-6Gi in a guide.
  2. A 1-replica Deployment that takes every GPU on its node deadlocks on RollingUpdate.
     The new pod waits Pending on `Insufficient nvidia.com/gpu`. Use `strategy: Recreate`.
  3. Service links inject `<SERVICE>_*` env vars into vLLM's `VLLM_*` namespace. A
     Service named `vllm` would set `VLLM_PORT=tcp://...`, and vLLM rejects that
     value. Use `enableServiceLinks: false`.
  4. The readiness probe's 1 s default timeout flaps under CPU contention. Use about 5 s.
     (Observed, not yet applied to the live Deployment.)
- **E2: no SGLang error reached.** The amd64-only xeon image pulls onto the arm64 node,
  because it is a single-platform manifest. It runs only because the Docker Desktop VM has
  Rosetta/qemu x86_64 binfmt handlers. `--help` took 5m05s. The launch was killed by a
  VM-wide OOM after 7m20s with no SGLang output beyond a deprecation warning.

Concerns:
1. Run 3 uses KV 256 MiB instead of the addendum's 1 GiB. Evidence and rationale are in
   "E1 run 2". Main was messaged before run 3, and the chief approved it afterwards. The flag
   line from `vllm serve --help=all` is in "E1 run 3".
2. **E2 caused a VM-wide OOM at 07:29:11Z that restarted my own E1 pod once.** Probe
   timeouts kept that pod NotReady until E2 ended. All kills in the kernel
   ring buffer are in my pods, and no other spike pod restarted, but the buffer starts at
   07:29:11, so earlier kills elsewhere cannot be ruled out from it. E1 serves again (verified 07:37:40Z).
3. Memory headroom on the Docker VM is the binding constraint for everyone. E1 alone uses
   about 4.0 GB, and the VM showed 1.3 to 2.3 GB "available" during this task.

## E0: image availability on worker3

At start (05:53Z) task A's pull of `vllm-openai-cpu:v0.30.0` was still running, so I
waited for it rather than start a second pull:

```
$ docker exec mokka-vr200-llm-worker3 crictl images | grep -E 'vllm|sglang'   # 05:53:21Z
(no rows)
$ docker exec mokka-vr200-llm-worker3 ctr -n k8s.io content active            # 06:00Z
layer-sha256:b78af0891ec0f6894070da76abd4077da98913b47f471d626b176ec5cf195e66	370.1MB	11 minutes
$ tail -2 /tmp/vr200-llm-spike-58fc971e/a-pull-cpu-worker3.log
=== 2026-09-23T06:09:22Z END node=mokka-vr200-llm-worker3 image=docker.io/vllm/vllm-openai-cpu:v0.30.0 PULL_RC=0
=== 2026-09-23T06:09:22Z START node=mokka-vr200-llm-worker3 image=docker.io/lmsysorg/sglang:v0.5.20-xeon
```

Pull of the 1322 MB (compressed, arm64) image took 20m26s on the shared link.

Image config (arm64 entry of the manifest list), from
`docker buildx imagetools inspect docker.io/vllm/vllm-openai-cpu:v0.30.0 --format '{{json .Image}}'`:

```
manifest list sha256:85d126740e78e9b7270b6cfc01159776d066c445609b7167faf32efc4a86f19d
  linux/arm64/v8 sha256:09e656588c2dc572240cb62a22f75681dc640a99c61537bbd55e9eb1dc3d4fbc
  linux/amd64    sha256:0fd700a207f4f4f0cc9c87fb425b5fa2aafa420c9affca904e2fd44920cbf5a7
linux/arm64:
  ENV PATH=/opt/venv/bin:/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
  ENV LD_PRELOAD=/usr/lib/aarch64-linux-gnu/libtcmalloc_minimal.so.4
  ENTRYPOINT ['vllm', 'serve'] CMD None WORKDIR /vllm-workspace
  (no LD_LIBRARY_PATH, no VLLM_TARGET_DEVICE in the image env)
```

So the pod's `PATH` is `/opt/nvml-mock/driver/usr/bin:` + the image PATH above,
`LD_LIBRARY_PATH` is just the NVML-only dir (the image sets none), and `LD_PRELOAD`
is left untouched (the pod does not set it, so the image's tcmalloc preload stays).

## E1: vLLM CPU build behind a Service

### E1.1 settings lookup (CPU backend env vars at v0.30.0)

Source fetched at tag v0.30.0 from raw.githubusercontent.com into
`/tmp/vr200-llm-spike-58fc971e/cpu/src-*`:

```
$ grep -n -A6 '"VLLM_CPU_KVCACHE_SPACE"' src-vllm_envs.py     # vllm/envs.py @v0.30.0
865:    # (CPU backend only) CPU key-value cache space.
866:    # default is None and will be set as 4 GB
867:    "VLLM_CPU_KVCACHE_SPACE": lambda: (
868:        int(os.getenv("VLLM_CPU_KVCACHE_SPACE", "0"))
869:        if "VLLM_CPU_KVCACHE_SPACE" in os.environ
870:        else None
$ sed -n 299,303p src-vllm_platforms_cpu.py                     # vllm/platforms/cpu.py @v0.30.0
        # Lagecy setting
        env_key = "VLLM_CPU_KVCACHE_SPACE"
        if env_key in os.environ and os.environ[env_key] != "":
            kv_cache_space = int(os.environ[env_key])
            cache_config.kv_cache_memory_bytes = kv_cache_space * GiB_bytes
$ grep -n 'kv-cache-memory' src-arg_utils.py                    # vllm/engine/arg_utils.py @v0.30.0
1273:            "--kv-cache-memory-bytes", **cache_kwargs["kv_cache_memory_bytes"]
```

So at v0.30.0 `VLLM_CPU_KVCACHE_SPACE` (integer GiB) still works but the code calls
it a legacy setting; it is mapped onto `--kv-cache-memory-bytes`, the generic
successor. Runs 1 and 2 used `VLLM_CPU_KVCACHE_SPACE=1` (1 GiB), as the addendum asks. Run 3,
the one that works, uses `--kv-cache-memory-bytes 268435456` instead; see "run 2" below for why.

Thread binding, from docs/getting_started/installation/cpu.md @v0.30.0 line 152:

```
- `VLLM_CPU_OMP_THREADS_BIND`: specify the CPU cores dedicated to the OpenMP threads, can be set as CPU id lists,
  `auto` (by default), or `nobind` (to disable binding to individual CPU cores and to inherit user-defined OpenMP
  variables). ... If set to `nobind`, the number of OpenMP threads is determined by the standard `OMP_NUM_THREADS`
  environment variable.
```

The pod has a 4-CPU CFS quota but its affinity mask is all 14 node CPUs (no static
CPU manager), so I set `VLLM_CPU_OMP_THREADS_BIND=nobind` + `OMP_NUM_THREADS=4`.
The engine log confirms it took effect:

```
(EngineCore pid=56) INFO 09-23 06:12:56 [ompmultiprocessing.py:185] 	VLLM_CPU_OMP_THREADS_BIND='nobind', auto_setup=False, skip_setup=True
```

Other choices, each with its source:
- `--enforce-eager`: on CPU, vLLM's default is an inductor compile of the model
  (cpu.py @v0.30.0 lines 331-351: `backend = "eager" if envs.VLLM_CPU_CI_ENV else "inductor"`).
  A gcc compile inside a 4Gi pod on a VM with ~4.4 GB free is an avoidable OOM risk,
  and speed is irrelevant here. vllm/config/vllm.py @v0.30.0 line 1546-1551: enforce
  eager sets `CompilationMode.NONE`. The log shows it: `Enforce eager set, disabling torch.compile and CUDAGraphs.`
- `/dev/shm` as a 1Gi Memory emptyDir: the arm docs launch with `--shm-size=4g`
  (cpu.arm.inc.md line 223); the k8s default is 64Mi, and the engine runs a
  multiprocess executor on CPU (cpu.py: `distributed_executor_backend = "mp"`).
- `VLLM_NO_USAGE_STATS=1` and `DO_NOT_TRACK=1` (envs.py lines 815-819) so the spike
  sends no usage-stats POST to `https://stats.vllm.ai`.
- dtype left at the model default (bf16): the node CPU reports `bf16` in
  `/proc/cpuinfo` Features, and cpu.py `supported_dtypes` returns bf16 for aarch64 Linux.

### E1 run 1: OOMKilled at 4Gi (recorded, then retried once)

Manifest `e1-vllm-cpu.run1.yaml` (`--max-model-len 4096 --enforce-eager`, CPU
defaults otherwise), applied 06:11:29Z. The init container staged NVML only:

```
$ kubectl --context kind-mokka-vr200-llm -n spike-cpu logs vllm-cpu-5bbf5f8745-vmb7t -c stage-nvml
lrwxrwxrwx 1 root root       17 Sep 23 05:45 libnvidia-ml.so -> libnvidia-ml.so.1
lrwxrwxrwx 1 root root       22 Sep 23 05:45 libnvidia-ml.so.1 -> libnvidia-ml.so.615.23
-rwxr-xr-x 1 root root 14123928 Sep 23 05:45 libnvidia-ml.so.615.23
```

The model downloaded (about 1 GB at about 1 MB/s while task A's xeon pull shared the
link), then the container was OOMKilled, 8 times in a row, each time at the same point:

```
$ cat e1-wait.log
2026-09-23T06:17:31Z FAILED pod=vllm-cpu-5bbf5f8745-vmb7t restarts=0 terminated=OOMKilled
$ kubectl --context kind-mokka-vr200-llm -n spike-cpu describe pod vllm-cpu-5bbf5f8745-vmb7t   (e1-run1-describe.txt)
    Last State:     Terminated
      Reason:       OOMKilled
      Exit Code:    137
      Started:      Wed, 23 Sep 2026 08:34:21 +0200
      Finished:     Wed, 23 Sep 2026 08:35:13 +0200
    Restart Count:  7
$ tail -5 e1-run1-last-attempt.log     # last lines before each kill
(Worker pid=80) INFO 09-23 06:35:11 [default_loader.py:430] Loading weights took 1.77 seconds
(EngineCore pid=56) WARNING 09-23 06:35:12 [torch_utils.py:275] OMP_NUM_THREADS=4 is set; leaving Torch threads at 4 for serving. ...
(EngineCore pid=56) INFO 09-23 06:35:12 [utils.py:320] Using LBHNC KV cache layout.
(Worker pid=80) INFO 09-23 06:35:12 [cpu_worker.py:271] Explicitly set (1.0/15.84) GiB for KV cache on node 0.
(EngineCore pid=56) INFO 09-23 06:35:12 [kv_cache_utils.py:2395] CPU KV cache size: 87,296 tokens, Maximum concurrency for 4,096 tokens per request: 21.31x
```

Kernel OOM-killer record from the node (`docker exec mokka-vr200-llm-worker3 dmesg`,
saved in `e1-run1-dmesg.txt`), which gives the exact per-process split at the kill:

```
[78478.861343] memory: usage 4194304kB, limit 4194304kB, failcnt 945
[78478.861511] anon 4247797760
[78478.861519] file 7925760
[78478.861522] shmem 53248
[78478.861845] Memory cgroup out of memory: Killed process 2218304 (VLLM::Worker) total-vm:8483048kB, anon-rss:2816968kB, ...
[78478.874289] Memory cgroup out of memory: Killed process 2217250 (vllm) total-vm:4745220kB, anon-rss:854788kB, ...
[78478.921067] Memory cgroup out of memory: Killed process 2218112 (VLLM::EngineCor) total-vm:4755376kB, anon-rss:462720kB, ...
[78478.918596] Memory cgroup out of memory: Killed process 2218111 (python) total-vm:44572kB, anon-rss:11520kB, ...
```

So the pod needs about 2.8 GB (worker) + 0.85 GB (API server) + 0.46 GB (engine core)
of anonymous memory, which is over 4 GiB. The worker's 2.8 GB is 0.92 GiB of weights
(`Checkpoint size: 0.92 GiB` in the log), the 1 GiB KV cache, and about 0.8 GB of other memory.
INFERENCE: that 0.8 GB is the torch runtime plus the warm-up dummy run, which is sized
by `max_num_batched_tokens` and `max_num_seqs`.

Why I changed more than max-model-len on the one retry: on CPU at v0.30.0 those two
defaults do not depend on max-model-len while chunked prefill is on (it is on,
`enable_chunked_prefill=True` in the config line):

```
$ sed -n 2782,2790p src-arg_utils.py
        if current_platform.is_cpu():
            default_max_num_batched_tokens = {
                ...
                UsageContext.OPENAI_API_SERVER: 2048 * world_size,
            default_max_num_seqs = {
                ...
                UsageContext.OPENAI_API_SERVER: 128 * world_size,
$ sed -n 2943,2951p src-arg_utils.py
2943:        if orig_max_num_batched_tokens is None:
            ...
2947:            if not self.enable_chunked_prefill:
                # If max_model_len is too short, use the default for higher throughput.
                self.max_num_batched_tokens = max(
```

Lowering only max-model-len would not have changed the warm-up size. The retry
therefore sets `--max-model-len 2048 --max-num-batched-tokens 512 --max-num-seqs 8`.
The KV cache stays at 1 GiB and the limits stay at 4Gi / 4 CPU, as the addendum requires.

Side observation: `(1.0/15.84) GiB` shows that vLLM measured "node memory" as the
whole 15.84 GiB VM and not the pod's 4 GiB cgroup. The node has no
`/sys/devices/system/node`, and in `get_memory_node_info` the non-NUMA fallback
returns psutil totals before the cgroup clamp runs
(`src-cpu_resource_utils.py`: line 131 `if not os.path.exists(meminfo_path):` returns the psutil
numbers early; the cgroup clamp `get_cgroup_memory_limit()` is only reached at line 164).
With an explicit KV size this does not matter. With `--gpu-memory-utilization`
sizing on a non-NUMA pod it would size against host RAM. INFERENCE, not tested.

### E1 rollout finding 1: RollingUpdate deadlocks on a 4-GPU pod

Applying the retry to the same Deployment left the new pod Pending, because the old
pod held all 4 `nvidia.com/gpu` on the only `track=cpu` node:

```
$ kubectl --context kind-mokka-vr200-llm -n spike-cpu get events --field-selector involvedObject.name=vllm-cpu-5f6596559b-4d47s
9s   Warning   FailedScheduling   pod/vllm-cpu-5f6596559b-4d47s   0/4 nodes are available: 1 Insufficient nvidia.com/gpu, 1 node(s) had untolerated taint(s), 2 node(s) didn't match Pod's node affinity/selector. preemption: ...
$ kubectl --context kind-mokka-vr200-llm -n spike-cpu get deploy vllm-cpu -o jsonpath='{.spec.strategy}'
{"rollingUpdate":{"maxSurge":"25%","maxUnavailable":"25%"},"type":"RollingUpdate"}
```

With 1 replica, 25% rounds to maxSurge 1 and maxUnavailable 0, so the rollout never
makes progress. Adding `strategy: {type: Recreate}` fixed it: the old ReplicaSet went to
0 and the pending pod was scheduled (06:47:52Z apply). A real GPU Deployment behaves the
same way. The simulated capacity reproduces this scheduling behaviour faithfully.

### E1 rollout finding 2: Service links inject into vLLM's env namespace

A Service named `vllm-cpu` makes the kubelet inject `VLLM_CPU_*` variables, and
vLLM warns about each one:

```
(APIServer pid=1) WARNING 09-23 06:12:06 [envs.py:2248] Unknown vLLM environment variable detected: VLLM_CPU_SERVICE_PORT
(APIServer pid=1) WARNING 09-23 06:12:06 [envs.py:2248] Unknown vLLM environment variable detected: VLLM_CPU_PORT_8000_TCP
... (8 such lines: VLLM_CPU_PORT, VLLM_CPU_SERVICE_HOST, VLLM_CPU_PORT_8000_TCP_ADDR, ..._PROTO, ..._PORT, VLLM_CPU_SERVICE_PORT_HTTP)
```

The warnings are harmless here, but a Service named `vllm` would inject `VLLM_PORT=tcp://...`,
and vLLM refuses to start with that value (`src-vllm_envs.py` line 507 `get_vllm_port`: "Raises: ValueError: If
VLLM_PORT is a URI, suggest k8s service discovery issue."). The final manifest sets
`enableServiceLinks: false`.

### E1 run 2 (the addendum's one retry): OOMKilled again at the same point

Manifest `e1-vllm-cpu.run2.yaml`: `--max-model-len 2048 --max-num-batched-tokens 512
--max-num-seqs 8`, KV still `VLLM_CPU_KVCACHE_SPACE=1`, plus `Recreate` and
`enableServiceLinks: false`.

```
$ cat e1-wait-run2.log
2026-09-23T06:52:07Z FAILED pod=vllm-cpu-5f6596559b-4d47s restarts=1 terminated=OOMKilled
$ kubectl ... logs deploy/vllm-cpu -c vllm --previous | tail -4
(Worker pid=80) INFO 09-23 06:52:05 [default_loader.py:430] Loading weights took 0.99 seconds
(EngineCore pid=57) INFO 09-23 06:52:06 [utils.py:320] Using LBHNC KV cache layout.
(Worker pid=80) INFO 09-23 06:52:06 [cpu_worker.py:271] Explicitly set (1.0/15.84) GiB for KV cache on node 0.
(EngineCore pid=57) INFO 09-23 06:52:06 [kv_cache_utils.py:2395] CPU KV cache size: 87,296 tokens, Maximum concurrency for 2,048 tokens per request: 42.62x
$ docker exec mokka-vr200-llm-worker3 dmesg | ... (e1-run2-dmesg.txt)
[79492.387190] memory: usage 4194304kB, limit 4194304kB, failcnt 1631
[79492.388735] anon 4257800192
[79492.389447] Memory cgroup out of memory: Killed process 2240098 (VLLM::Worker) ... anon-rss:2822832kB ...
[79492.390543] Memory cgroup out of memory: Killed process 2238836 (vllm) ... anon-rss:856704kB ...
[79492.397265] Memory cgroup out of memory: Killed process 2239952 (VLLM::EngineCor) ... anon-rss:464884kB ...
```

The worker's RSS at the kill was the same as in run 1 (2822832 vs 2816968 kB), so the
smaller warm-up changed nothing. The source shows why: `determine_available_memory`
runs the warm-up first and logs "Explicitly set ... GiB for KV cache" only afterwards
(`src-cpu_worker.py` lines 215-217 `if self._should_warm_up_model(): self.model_runner.warming_up_model()`,
and the log call comes at the end of the function). So the kill happens during the 1 GiB
KV allocation, not during warm-up.

Measured per-process RSS before the weights loaded (06:48:44Z, run 2):

```
$ kubectl ... exec deploy/vllm-cpu -c vllm -- sh -c '... VmRSS per /proc/<pid> ...'
anon 1938649088
1 rss_kB=1043808 /opt/venv/bin/python /opt/venv/bin/vllm serve Qwen/Qwen2.5-0
56 rss_kB=22088 /opt/venv/bin/python -c from multiprocessing.resource_tracke
57 rss_kB=647376 VLLM::EngineCore
80 rss_kB=748560 VLLM::Worker
```

Breakdown: worker 0.75 GB baseline + 0.99 GB weights + 1.07 GB KV = 2.81 GB, which matches
the 2.82 GB at the kill. Add the API server (0.86 GB) and the engine core (0.46 GB), and the
total is about 4.14 GB against a limit of 4.19 GB (4Gi) before any request runs. **At v0.30.0 the
vLLM CPU build runs three processes that each import torch. That does not fit
"limit 4Gi" and "KV 1 GiB" at once.** The addendum's one retry was used. I told main
and made one more attempt (run 3) that keeps the 4Gi / 4 CPU limits and cuts the KV cache instead.
`VLLM_CPU_KVCACHE_SPACE` is `int(...)` GiB (envs.py line 868), so values under 1 GiB cannot be
written that way. Run 3 uses the successor flag `--kv-cache-memory-bytes 268435456` (256 MiB)
and drops the env var. The env var would win if set: cpu.py line 301 applies it only
`if env_key in os.environ`.

### E1 run 3: Ready, 0 restarts (pod `vllm-cpu-b4cbd5f5d-ndv7j`)

The chief approved the 256 MiB KV setting after run 3 had already started. The
approval asked for the flag to be checked in `vllm serve --help` at v0.30.0. At this version
plain `--help` shows only an 81-line summary and points to `--help=<ConfigGroup>`, so the flag
line comes from `--help=all`. That ran as a one-shot pod, `e1-serve-help-pod.yaml`, same image,
Succeeded exit 0, 07:55:28Z to 07:56:11Z, log `e1-serve-help.log`:

```
help_rc=0
lines=81
help_all_rc=0
1003:  --kv-cache-memory-bytes KV_CACHE_MEMORY_BYTES
1004-                        Size of KV Cache per GPU in bytes. By default, this is
1005-                        set to None and vllm can automatically infer the kv
1006-                        cache size based on gpu_memory_utilization. However,
1007-                        users may want to manually specify the kv cache memory
--- head of plain --help
usage: vllm serve [model_tag] [options]
Search by using: `--help=<ConfigGroup>` to explore options by section (e.g.,
--help=ModelConfig, --help=Frontend)
```

The installed code (`vllm 0.30.0+cpu`, from `pip show` in the image) has it, and the serving
process parsed and applied it:

```
$ kubectl ... exec curl-client -c curl -- grep -n '"--kv-cache-memory-bytes"' /opt/venv/lib/python3.12/site-packages/vllm/engine/arg_utils.py
1273:            "--kv-cache-memory-bytes", **cache_kwargs["kv_cache_memory_bytes"]
$ grep -o "non-default args: {[^}]*}" e1-run3-vllm.log
non-default args: {'model_tag': 'Qwen/Qwen2.5-0.5B-Instruct', 'host': '0.0.0.0', 'model': 'Qwen/Qwen2.5-0.5B-Instruct', 'max_model_len': 2048, 'enforce_eager': True, 'kv_cache_memory_bytes': 268435456, 'max_num_batched_tokens': 512, 'max_num_seqs': 8}
```

```
$ cat e1-wait-run3.log
2026-09-23T07:05:24Z READY pod=vllm-cpu-b4cbd5f5d-ndv7j restarts=0
WAIT_RC=0
$ grep -n -E 'KV cache|init engine|Starting vLLM|startup complete' e1-run3-vllm.log
46:(Worker pid=90) INFO 09-23 07:05:04 [cpu_worker.py:271] Explicitly set (0.25/15.84) GiB for KV cache on node 0.
47:(EngineCore pid=67) INFO 09-23 07:05:04 [kv_cache_utils.py:2395] CPU KV cache size: 21,760 tokens, Maximum concurrency for 2,048 tokens per request: 10.62x
48:(EngineCore pid=67) INFO 09-23 07:05:05 [core.py:379] init engine (profile, create kv cache, warmup model) took 0.96 s
60:(APIServer pid=1) INFO 09-23 07:05:16 [entry.py:139] Starting vLLM server on http://0.0.0.0:8000
89:(APIServer pid=1) INFO:     Application startup complete.
```

Memory headroom is thin, even with a 256 MiB KV cache:

```
$ kubectl ... exec vllm-cpu-b4cbd5f5d-ndv7j -c vllm -- sh -c 'cat memory.peak; ...'    (after 5 completions)
peak=4082409472 current=4014432256 max=4294967296
$ ... per-process VmRSS (between 07:05:24Z Ready and the first request at 07:17:26Z)
1 rss_kB=947148 /opt/venv/bin/python /opt/venv/bin/vllm serve Qwen/Qwen2.5-0
66 rss_kB=12140 /opt/venv/bin/python -c from multiprocessing.resource_tracke
67 rss_kB=601280 VLLM::EngineCore
90 rss_kB=2342912 VLLM::Worker
```

The worker is at 2.34 GB, about 0.34 GB above baseline + weights + KV (0.75 + 0.99 + 0.27).
INFERENCE: this is download or warm-up memory that tcmalloc (`LD_PRELOAD`ed by the
image) keeps instead of returning to the OS. The peak is 4.08 GB of 4.29 GB. Sequential
single requests are fine. Concurrent load at 4Gi is untested. For a guide, 5-6Gi is the
comfortable size for this model.

### E1.2 platform detection with mock NVML present

**The CPU build selects the CPU platform even though it loads the mock NVML and
sees 4 simulated VR200 GPUs through it.** No override was needed.

Startup log (INFO level; the per-plugin detection lines are DEBUG at v0.30.0 and not shown):

```
$ grep -o 'device_config=[a-z]*' e1-run3-vllm.log
device_config=cpu
$ sed -n 32p e1-run3-vllm.log
(Worker pid=90) INFO 09-23 06:58:09 [cpu_model_runner.py:130] Starting to load model Qwen/Qwen2.5-0.5B-Instruct...
$ sed -n 46p e1-run3-vllm.log
(Worker pid=90) INFO 09-23 07:05:04 [cpu_worker.py:271] Explicitly set (0.25/15.84) GiB for KV cache on node 0.
```

(`device_config=cpu` comes from the engine's config line: `Initializing a V1 LLM engine (v0.30.0)
with config: ... dtype=torch.bfloat16, ... device_config=cpu, ...`. The worker class is
`cpu_worker` and the runner is `cpu_model_runner`.)

Every serving process did load the mock NVML during detection, and none loaded any libcuda.
The same grep alternation matches `libnvidia-ml`, so it could also have matched `libcuda`:

```
$ kubectl ... exec vllm-cpu-b4cbd5f5d-ndv7j -c vllm -- sh -c 'for p in 1 67 90; do grep -E "libnvidia-ml|libcuda" /proc/$p/maps | awk "{print \$6}" | sort -u; done'
pid 1 (/opt/venv/bin/python /opt/venv/bin/vllm ):
/opt/nvml-only/libnvidia-ml.so.615.23
pid 67 (VLLM::EngineCore                        ):
/opt/nvml-only/libnvidia-ml.so.615.23
pid 90 (VLLM::Worker                            ):
/opt/nvml-only/libnvidia-ml.so.615.23
positive control (libtcmalloc in pid 90):
/usr/lib/aarch64-linux-gnu/libtcmalloc_minimal.so.4.5.18
```

Why it still picks CPU: `cuda_platform_plugin` in vllm/platforms/__init__.py @v0.30.0 is
`is_cuda = (pynvml.nvmlDeviceGetCount() > 0 and not vllm_version_matches_substr("cpu"))`.
A torch-free probe (`e1-platform-probe-light.py`) recomputes both inputs inside the
serving pod with vLLM's own vendored pynvml. It is light on purpose: the pod sits at 4.0 of 4.29 GB,
so a second torch import in that cgroup would OOM the server.

```
$ kubectl --context kind-mokka-vr200-llm -n spike-cpu exec -i vllm-cpu-b4cbd5f5d-ndv7j -c vllm -- python3 - < e1-platform-probe-light.py
vendored pynvml = /opt/venv/lib/python3.12/site-packages/vllm/third_party/pynvml.py
libnvidia-ml mapped from = ['/opt/nvml-only/libnvidia-ml.so.615.23']
nvmlDeviceGetCount() = 4
  gpu0: name='NVIDIA Graphics Device' uuid=GPU-307f0000-0000-0000-0000-000000000000 mem_total=309237645312 cc=10.7
  gpu1: name='NVIDIA Graphics Device' uuid=GPU-307f0000-0000-0000-0000-000000000001 mem_total=309237645312 cc=10.7
  gpu2: name='NVIDIA Graphics Device' uuid=GPU-307f0000-0000-0000-0000-000000000002 mem_total=309237645312 cc=10.7
  gpu3: name='NVIDIA Graphics Device' uuid=GPU-307f0000-0000-0000-0000-000000000003 mem_total=309237645312 cc=10.7
nvmlSystemGetDriverVersion() = 615.23
importlib.metadata.version('vllm') = '0.30.0+cpu'
vllm_version_matches_substr('cpu') = True
cuda_platform_plugin is_cuda = False
PROBE_RC=0
```

So the guard works as written. NVML says 4 GPUs, the `+cpu` local version suppresses
CUDA, and `cpu_platform_plugin` wins via the same substring. INFERENCE (from the source,
not observed): the guard depends only on the wheel's version string. A CUDA wheel with
the mock NVML present takes the CUDA branch, which is task C's lane.

Env as seen by the serving container (image PATH appended, image LD_PRELOAD kept):

```
$ kubectl ... exec vllm-cpu-b4cbd5f5d-ndv7j -c vllm -- env | grep ...
HF_HOME=/tmp/hf
LD_LIBRARY_PATH=/opt/nvml-only
LD_PRELOAD=/usr/lib/aarch64-linux-gnu/libtcmalloc_minimal.so.4
MOCK_NVML_CONFIG=/opt/nvml-mock/driver/config/config.yaml
PATH=/opt/nvml-mock/driver/usr/bin:/opt/venv/bin:/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
DO_NOT_TRACK=1
OMP_NUM_THREADS=4
VLLM_CPU_OMP_THREADS_BIND=nobind
VLLM_NO_USAGE_STATS=1
```

`enableServiceLinks: false` removed the warnings (0 in run 3 vs 8 in run 1):

```
$ grep -c 'Unknown vLLM environment variable' e1-run1-last-attempt.log e1-run3-vllm.log
8 / 0
```

### E1.3 API calls from inside the cluster

Client: a throwaway pod `curl-client` in spike-cpu (`e1-client-pod.yaml`, same image, which
ships curl, so no extra pull), calling the Service DNS name. Script `e1-api.sh`, log `e1-api.log`:

```
=== 2026-09-23T07:17:26Z GET /v1/models
{"object":"list","data":[{"id":"Qwen/Qwen2.5-0.5B-Instruct","object":"model","created":1790147847,"owned_by":"vllm","root":"Qwen/Qwen2.5-0.5B-Instruct","parent":null,"max_model_len":2048,"permission":[{...}]}]}
HTTP_STATUS=200 TIME_TOTAL=0.112370s
=== 2026-09-23T07:17:27Z POST /v1/completions (max_tokens 16)
  -d '{"model":"Qwen/Qwen2.5-0.5B-Instruct","prompt":"The capital of France is","max_tokens":16,"temperature":0}'
{"id":"cmpl-bd59746cae7124b9","object":"text_completion","created":1790147847,"model":"Qwen/Qwen2.5-0.5B-Instruct","choices":[{"index":0,"text":" Paris. It was founded in 789 AD by Charlemagne,","logprobs":null,"finish_reason":"length","stop_reason":null,"token_ids":null,"prompt_logprobs":null,"prompt_token_ids":null,"routed_experts":null}],"service_tier":null,"system_fingerprint":"vllm-0.30.0-c25bd4ff","usage":{"prompt_tokens":5,"total_tokens":21,"completion_tokens":16,"prompt_tokens_details":null,"completion_tokens_details":null},"kv_transfer_params":null,"ec_transfer_params":null,"metrics":null}
HTTP_STATUS=200 TIME_TOTAL=7.134225s
=== 2026-09-23T07:17:35Z POST /v1/completions again (warm)
{"id":"cmpl-b1e0a2d7f86ef590",...,"choices":[{"index":0,"text":" a software platform for managing and deploying applications. It provides an open-source, scalable","finish_reason":"length",...}],...,"usage":{"prompt_tokens":3,"total_tokens":19,"completion_tokens":16,...}}
HTTP_STATUS=200 TIME_TOTAL=3.761000s
=== 2026-09-23T07:17:39Z GET /metrics (vllm:* sample lines)
HTTP_STATUS=200
360                                   <- count of lines starting with "vllm:"
vllm:estimated_flops_per_gpu_total{engine="0",model_name="Qwen/Qwen2.5-0.5B-Instruct"} 0.0
vllm:num_requests_running{engine="0",model_name="Qwen/Qwen2.5-0.5B-Instruct"} 0.0
vllm:num_requests_waiting{engine="0",model_name="Qwen/Qwen2.5-0.5B-Instruct"} 0.0
vllm:engine_sleep_state{engine="0",model_name="Qwen/Qwen2.5-0.5B-Instruct",sleep_state="awake"} 1.0
vllm:kv_cache_usage_perc{engine="0",model_name="Qwen/Qwen2.5-0.5B-Instruct"} 0.0
vllm:prefix_cache_queries_total{engine="0",model_name="Qwen/Qwen2.5-0.5B-Instruct"} 8.0
=== selected counters
vllm:prompt_tokens_total{engine="0",model_name="Qwen/Qwen2.5-0.5B-Instruct"} 8.0
vllm:generation_tokens_total{engine="0",model_name="Qwen/Qwen2.5-0.5B-Instruct"} 32.0
vllm:request_success_total{engine="0",finished_reason="length",model_name="Qwen/Qwen2.5-0.5B-Instruct"} 2.0
```

The counters match the two completions: 5+3 prompt tokens, 2x16 generated, 2 finished on length.
The Service routes to the pod:

```
$ kubectl --context kind-mokka-vr200-llm -n spike-cpu get endpointslices -l kubernetes.io/service-name=vllm-cpu
NAME             ADDRESSTYPE   PORTS   ENDPOINTS    AGE
vllm-cpu-ms5v6   IPv4          8000    10.244.2.6   66m
```

### E1.4 nvidia-smi from the serving pod (log `e1-nvidia-smi.log`)

The same pod that served the tokens above:

```
$ kubectl --context kind-mokka-vr200-llm -n spike-cpu exec vllm-cpu-b4cbd5f5d-ndv7j -c vllm -- nvidia-smi -L
GPU 0: NVIDIA Graphics Device (UUID: GPU-307f0000-0000-0000-0000-000000000000)
GPU 1: NVIDIA Graphics Device (UUID: GPU-307f0000-0000-0000-0000-000000000001)
GPU 2: NVIDIA Graphics Device (UUID: GPU-307f0000-0000-0000-0000-000000000002)
GPU 3: NVIDIA Graphics Device (UUID: GPU-307f0000-0000-0000-0000-000000000003)
RC=0
$ ... exec vllm-cpu-b4cbd5f5d-ndv7j -c vllm -- nvidia-smi --query-gpu=index,name,uuid,memory.total,compute_cap,driver_version --format=csv
index, name, uuid, memory.total [MiB], compute_cap, driver_version
0, NVIDIA Graphics Device, GPU-307f0000-0000-0000-0000-000000000000, 294912 MiB, 10.7, 615.23
1, NVIDIA Graphics Device, GPU-307f0000-0000-0000-0000-000000000001, 294912 MiB, 10.7, 615.23
2, NVIDIA Graphics Device, GPU-307f0000-0000-0000-0000-000000000002, 294912 MiB, 10.7, 615.23
3, NVIDIA Graphics Device, GPU-307f0000-0000-0000-0000-000000000003, 294912 MiB, 10.7, 615.23
RC=0
$ ... exec ... -- sh -c 'command -v nvidia-smi; ls /dev/nvidia*; echo NVIDIA_VISIBLE_DEVICES=$NVIDIA_VISIBLE_DEVICES'
/opt/nvml-mock/driver/usr/bin/nvidia-smi
/dev/nvidia0
/dev/nvidia1
/dev/nvidia2
/dev/nvidia3
NVIDIA_VISIBLE_DEVICES=GPU-307f0000-0000-0000-0000-000000000002,GPU-307f0000-0000-0000-0000-000000000003,GPU-307f0000-0000-0000-0000-000000000000,GPU-307f0000-0000-0000-0000-000000000001
$ kubectl ... get pod vllm-cpu-b4cbd5f5d-ndv7j -o jsonpath='{.spec.containers[0].resources}'
{"limits":{"cpu":"4","memory":"4Gi","nvidia.com/gpu":"4"},"requests":{"cpu":"2","memory":"2Gi","nvidia.com/gpu":"4"}}
$ kubectl --context kind-mokka-vr200-llm describe node mokka-vr200-llm-worker3 | grep nvidia.com/gpu
  nvidia.com/gpu:     4          (Capacity)
  nvidia.com/gpu:     4          (Allocatable)
  nvidia.com/gpu     4             4      (Allocated requests / limits)
```

### E1.5 timing (run 3)

```
$ kubectl ... get pod vllm-cpu-b4cbd5f5d-ndv7j -o jsonpath=conditions
created=2026-09-23T06:57:18Z
PodScheduled=True at 2026-09-23T06:57:18Z
Initialized=True at 2026-09-23T06:57:19Z
vllm startedAt=2026-09-23T06:57:19Z restarts=0
Ready=True at 2026-09-23T07:05:19Z
$ grep -n 'Time spent downloading' e1-run3-vllm.log
36:(Worker pid=90) INFO 09-23 07:05:01 [weight_utils.py:558] Time spent downloading weights for Qwen/Qwen2.5-0.5B-Instruct: 410.077329 seconds
```

| Metric | Value |
|---|---|
| Pod creation to Ready (image already on node, cold HF cache) | **8m01s** (06:57:18Z to 07:05:19Z) |
| of which: weight download from HF (emptyDir cache, shared link) | 410.1 s |
| engine init (profile, KV cache, warm-up) | 0.96 s (log line 48) |
| weights loaded to "Starting vLLM server" | 07:05:03Z to 07:05:16Z, about 13 s |
| INFERENCE: creation to Ready with a warm cache | about 1m10s (8m01s minus the 410 s download) |
| Observed warm restart (same pod, cached weights, during E2 contention) | container start 07:29:14Z to `Starting vLLM server` 07:31:15, about 2m01s. Ready only at 07:36:23Z because of probe timeouts (see E2 side effects) |
| `/v1/completions`, 16 tokens, first request | 7.13 s |
| same, next 4 requests (`e1-api.log`, `e1-latency.log`) | 3.76 s, 5.52 s, 6.76 s, 5.86 s |
| `/v1/models` | 0.11 s |

CPU throttling was negligible during those requests (`nr_throttled 6` of `nr_periods 12624`,
`cpu.max 400000 100000`). INFERENCE: roughly 3-4 tokens/s comes from bf16 on
NEON inside a VM shared with 4 other kind clusters, not from the pod's quota.

**The E1 Deployment is LEFT RUNNING** (`deploy/vllm-cpu` in spike-cpu, 1/1 Ready, pod
`vllm-cpu-b4cbd5f5d-ndv7j`) for the chief to re-verify. It had 0 restarts through E1. During E2
it got 1 restart, from a VM-wide OOM (see E2 side effects), and it served again at 07:37:40Z. `curl-client` is also
left running for that re-verification (1 sleep process, limit 128Mi). Delete both with
`kubectl --context kind-mokka-vr200-llm -n spike-cpu delete deploy/vllm-cpu pod/curl-client`.

### Final Deployment YAML (live objects match: `kubectl diff -f e1-vllm-cpu.yaml` gives DIFF_RC=0)

File: `/tmp/vr200-llm-spike-58fc971e/cpu/e1-vllm-cpu.yaml`

```yaml
# Task E1: vLLM CPU build served behind a Service on a Mokka vr200 node.
# Scheduled against nvidia.com/gpu: 4 like a GPU deployment; tokens computed on CPU.
# Mock driver per task A 6.3, but NVML only on LD_LIBRARY_PATH (no mock libcuda).
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vllm-cpu
  namespace: spike-cpu
  labels:
    app.kubernetes.io/name: vllm-cpu
    app.kubernetes.io/part-of: spike-vr200-llm
spec:
  replicas: 1
  # The pod takes all 4 GPUs on its node. RollingUpdate (maxSurge 1,
  # maxUnavailable 0 at 1 replica) leaves the new pod Pending on
  # "Insufficient nvidia.com/gpu" forever, so replace instead of surge.
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app.kubernetes.io/name: vllm-cpu
  template:
    metadata:
      labels:
        app.kubernetes.io/name: vllm-cpu
        app.kubernetes.io/part-of: spike-vr200-llm
    spec:
      nodeSelector:
        spike.mokka/track: cpu
      # Service links inject VLLM_CPU_* env vars from the Service name into
      # vLLM's env namespace; a Service named "vllm" would inject
      # VLLM_PORT=tcp://..., which vLLM rejects (envs.py get_vllm_port).
      enableServiceLinks: false
      initContainers:
        # Copy only libnvidia-ml.so* out of the mock driver root, so the CPU
        # build sees the mock NVML but never the mock libcuda shim.
        - name: stage-nvml
          image: docker.io/vllm/vllm-openai-cpu:v0.30.0
          imagePullPolicy: IfNotPresent
          command: ["sh", "-c"]
          args:
            - cp -a /opt/nvml-mock/driver/usr/lib64/libnvidia-ml.so* /opt/nvml-only/ && ls -l /opt/nvml-only
          volumeMounts:
            - name: mock-root
              mountPath: /opt/nvml-mock
              readOnly: true
            - name: nvml-only
              mountPath: /opt/nvml-only
      containers:
        - name: vllm
          image: docker.io/vllm/vllm-openai-cpu:v0.30.0
          imagePullPolicy: IfNotPresent
          # Image ENTRYPOINT is ["vllm", "serve"].
          args:
            - Qwen/Qwen2.5-0.5B-Instruct
            - --host
            - 0.0.0.0
            - --port
            - "8000"
            # Runs 1 and 2 (KV cache 1 GiB) were OOMKilled at 4Gi while the
            # KV cache was allocated. The API server, engine core and worker
            # each load torch (~0.86 + 0.46 + 0.75 GB) before weights (0.99 GB),
            # so KV is 256 MiB here (~21k tokens). VLLM_CPU_KVCACHE_SPACE only
            # takes whole GiB, so use the generic flag.
            - --kv-cache-memory-bytes
            - "268435456"
            - --max-model-len
            - "2048"
            # Bound runtime batch memory for a 4Gi pod.
            - --max-num-batched-tokens
            - "512"
            - --max-num-seqs
            - "8"
            - --enforce-eager
          ports:
            - name: http
              containerPort: 8000
          env:
            # Image PATH is /opt/venv/bin:/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
            - name: PATH
              value: /opt/nvml-mock/driver/usr/bin:/opt/venv/bin:/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
            # Image sets no LD_LIBRARY_PATH; NVML only, no mock libcuda.
            - name: LD_LIBRARY_PATH
              value: /opt/nvml-only
            - name: MOCK_NVML_CONFIG
              value: /opt/nvml-mock/driver/config/config.yaml
            - name: HF_HOME
              value: /tmp/hf
            # docs cpu.md @v0.30.0: nobind hands thread count to OMP_NUM_THREADS.
            # The pod has a 4-CPU CFS quota but sees all 14 cores, so "auto"
            # would start one thread per visible core.
            - name: VLLM_CPU_OMP_THREADS_BIND
              value: nobind
            - name: OMP_NUM_THREADS
              value: "4"
            # No outbound usage-stats POST from the spike.
            - name: VLLM_NO_USAGE_STATS
              value: "1"
            - name: DO_NOT_TRACK
              value: "1"
          resources:
            requests:
              cpu: "2"
              memory: 2Gi
            limits:
              cpu: "4"
              memory: 4Gi
              nvidia.com/gpu: 4
          readinessProbe:
            httpGet:
              path: /health
              port: http
            periodSeconds: 5
            failureThreshold: 3
          volumeMounts:
            - name: mock-root
              mountPath: /opt/nvml-mock
              readOnly: true
            - name: nvml-only
              mountPath: /opt/nvml-only
              readOnly: true
            - name: hf-cache
              mountPath: /tmp/hf
            - name: dshm
              mountPath: /dev/shm
      volumes:
        - name: mock-root
          hostPath:
            path: /var/lib/nvml-mock
            type: Directory
        - name: nvml-only
          emptyDir: {}
        - name: hf-cache
          emptyDir: {}
        - name: dshm
          emptyDir:
            medium: Memory
            sizeLimit: 1Gi
---
apiVersion: v1
kind: Service
metadata:
  name: vllm-cpu
  namespace: spike-cpu
  labels:
    app.kubernetes.io/name: vllm-cpu
    app.kubernetes.io/part-of: spike-vr200-llm
spec:
  selector:
    app.kubernetes.io/name: vllm-cpu
  ports:
    - name: http
      port: 8000
      targetPort: http
```

## E2: SGLang xeon build on arm64 (20-minute time box: 07:20:04Z to 07:37:33Z)

**Result: there was no clean "cannot run on arm64" failure. The amd64 image pulls and
executes on this arm64 node, but only because Docker Desktop's Linux VM registers
Rosetta/qemu x86_64 binfmt handlers. `--help` took 5 minutes under emulation. The real
launch never printed anything beyond a deprecation warning before a VM-wide OOM killed
it after 7m20s. No SGLang code path produced a verbatim error.** INFERENCE: on a real
arm64 host (Grace/Vera) with no x86 binfmt handler, the same pod fails at exec
with `exec format error`. I did not test this, because every node here has the handler.

### E2.1 pull: containerd accepted an amd64-only image on the arm64 node

The tag is a single-platform manifest, not a list, so containerd has no platform
list to reject it against:

```
$ docker buildx imagetools inspect docker.io/lmsysorg/sglang:v0.5.20-xeon
Name:      docker.io/lmsysorg/sglang:v0.5.20-xeon
MediaType: application/vnd.docker.distribution.manifest.v2+json
Digest:    sha256:2b11d06617917b0cbbddf0ffe3da54ce4310a3bc4672497e1cd46069abf58a8a
$ grep -n -E 'START|END' a-pull-cpu-worker3.log    (task A's pull, not mine)
4:=== 2026-09-23T06:09:22Z START node=mokka-vr200-llm-worker3 image=docker.io/lmsysorg/sglang:v0.5.20-xeon
6:=== 2026-09-23T06:39:27Z END node=mokka-vr200-llm-worker3 image=docker.io/lmsysorg/sglang:v0.5.20-xeon PULL_RC=0
$ docker exec mokka-vr200-llm-worker3 crictl images | grep sglang
docker.io/lmsysorg/sglang                       v0.5.20-xeon         88bd32f6becef       1.93GB
$ docker exec mokka-vr200-llm-worker3 sh -c 'crictl inspecti docker.io/lmsysorg/sglang:v0.5.20-xeon | grep -m2 -E "\"architecture\"|\"os\""; uname -m'
      "architecture": "amd64",
      "os": "linux",
aarch64
```

### E2.2 why it executes: x86_64 binfmt handlers in the Docker Desktop VM

```
$ docker exec mokka-vr200-llm-worker3 ls /proc/sys/fs/binfmt_misc/
aarch64 arm i386 mips64 mips64le ppc64le register riscv64 rosetta rosetta-wrapper s390x status x86_64
$ ... cat /proc/sys/fs/binfmt_misc/rosetta      (x86_64 is the same magic, interpreter /usr/bin/qemu-x86_64)
enabled
interpreter /run/rosetta/rosetta
flags: POCF
magic 7f454c4602010100000000000000000002003e00
$ docker exec mokka-vr200-llm-worker3 ps -eo pid,rss,args | grep launch_serve[r]
   7606 279724 /run/rosetta/rosetta /opt/.venv/bin/python3 python3 -m sglang.launch_server --model-path Qwen/Qwen2.5-0.5B-Instruct --device cpu --host 0.0.0.0 --port 30000
```

The node kernel is the Docker Desktop VM's, so the `F` (fix-binary) flag makes the
handler work inside every container. SGLang ran as x86_64 under Rosetta. INFERENCE:
Rosetta does not implement AVX-512 or AMX, the ISA this image targets. Even with enough
memory the CPU kernels would probably hit SIGILL or fall back. It never got that far,
so this is not observed.

### E2.3 flags checked with --help (pod `e2-sglang-xeon-help.yaml`, log `e2-help.log`, 2453 lines)

```
phase=Succeeded exit=0 reason=Completed started=2026-09-23T07:20:17Z finished=2026-09-23T07:25:22Z   <- 5m05s for --help
/opt/.venv/lib/python3.12/site-packages/sglang/launch_server.py:71: UserWarning: 'python -m sglang.launch_server' is still supported, but 'sglang serve' is the recommended entrypoint.
usage: sglang serve [-h] --model-path MODEL_PATH
446:  --model-path MODEL_PATH, --model MODEL_PATH
888:  --device DEVICE       The device to use ('cuda', 'xpu', 'hpu', 'npu', 'cpu',
889-                        'musa'). Defaults to auto-detection if not specified.
931:  --host HOST           The host of the HTTP server.
932:  --port PORT           The port of the HTTP server.
1234:  --attention-backend {triton,torch_native,...,intel_amx,ascend,intel_xpu}
```

### E2.4 launch (pod `e2-sglang-xeon-launch.yaml`: the brief's command + `--host 0.0.0.0`, limit 1Gi / 2 CPU, no GPU request since E1 holds all 4)

The limit was 1Gi because the VM had 1.3 GB "available" at 07:20Z (`free -m`), and
E1 had to stay up. Entire container log (`e2-launch.log`, 3 lines):

```
/opt/.venv/lib/python3.12/site-packages/sglang/launch_server.py:71: UserWarning: 'python -m sglang.launch_server' is still supported, but 'sglang serve' is the recommended entrypoint.
  Example: sglang serve --model-path <model> [options]
  warnings.warn(
```

Then (`e2-launch-describe.txt`, kernel ring buffer via `docker exec mokka-vr200-llm-worker3 dmesg -T`):

```
    State:          Terminated
      Reason:       OOMKilled
      Exit Code:    137
      Started:      Wed, 23 Sep 2026 09:28:56 +0200
      Finished:     Wed, 23 Sep 2026 09:36:16 +0200
[Wed Sep 23 07:36:14 2026] oom-kill:constraint=CONSTRAINT_NONE,nodemask=(null),mems_allowed=0,global_oom,task_memcg=/docker/2c88b941f3e6.../kubelet-kubepods-burstable-pod23aa06f6_aaaa_4aff_b6af_663dad8f1a91...
[Wed Sep 23 07:36:14 2026] Out of memory: Killed process 2328465 (python3) total-vm:3055720kB, anon-rss:544788kB, file-rss:640kB, shmem-rss:0kB, UID:0 pgtables:2496kB oom_score_adj:985
```

`global_oom` / `CONSTRAINT_NONE`: the Docker VM ran out of memory, not the pod (545 MB
RSS against a 1Gi limit). The kubelet still reports it as OOMKilled. Pod UID 23aa06f6 is
`sglang-xeon-launch`, and `2c88b941f3e6` is the `mokka-vr200-llm-worker3` container ID.

### E2 side effect on E1 (my doing, recorded)

Running E2 next to E1 on a starved VM disrupted E1 twice:

1. **A VM-wide OOM at 07:29:11Z killed the E1 serving container** (15 s after the
   launch pod started):
   ```
   [Wed Sep 23 07:29:11 2026] oom-kill:constraint=CONSTRAINT_NONE,...,global_oom,task_memcg=.../kubelet-kubepods-burstable-pod7b9ddcec_e730_4f24_99f8_aebd23ed1b22...
   [Wed Sep 23 07:29:11 2026] Out of memory: Killed process 2256135 (VLLM::Worker) total-vm:7549624kB, anon-rss:2308596kB, ... oom_score_adj:874
   [Wed Sep 23 07:29:11 2026] Out of memory: Killed process 2254814 (vllm) total-vm:4855260kB, anon-rss:943608kB, ... oom_score_adj:874
   [Wed Sep 23 07:29:11 2026] Out of memory: Killed process 2255972 (VLLM::EngineCor) total-vm:4953860kB, anon-rss:599752kB, ... oom_score_adj:874
   $ kubectl ... get pods -o custom-columns=NAME,UID,RESTARTS,LAST,LASTFIN
   vllm-cpu-b4cbd5f5d-ndv7j   7b9ddcec-e730-4f24-99f8-aebd23ed1b22   Running   true   1   OOMKilled   2026-09-23T07:29:12Z
   ```
   The VM's kernel ring buffer now starts at 07:29:11 (`dmesg -T | head -1`). It holds 8
   `Killed process` lines, and all of them are the two events above, in my pods. No other spike pod shows a
   restart (`kubectl get pods -A`: spike-vllm/vllm-ladder, spike-sglang/sglang-ladder,
   spike-libcuda/f-census-* all RESTARTS 0). I cannot rule out kills in other workers'
   pods before 07:29:11 from dmesg, because the buffer rotated.
2. **Readiness probe timeouts throughout E2.** The default `timeoutSeconds: 1` fails while the
   Rosetta process competes for the VM's CPUs:
   ```
   2026-09-23T07:21:05Z   2026-09-23T07:34:20Z   40   Unhealthy   Readiness probe failed: Get "http://10.244.2.6:8000/health": context deadline exceeded (Client.Timeout exceeded while awaiting headers)
   ```
   After the OOM restart, vLLM logged `Starting vLLM server` at 07:31:15, but the pod only
   turned Ready at 07:36:23Z, after E2 died. A guide manifest should set
   `timeoutSeconds: 5` or so on the readiness probe. I did not change the live
   Deployment, because it is left for the chief to re-verify as is.

E1 after E2 was cleaned up (`e1-reverify-after-e2.log`):

```
2026-09-23T07:37:40Z
deployment.apps/vllm-cpu   1/1     1            1           86m
pod/vllm-cpu-b4cbd5f5d-ndv7j   1/1     Running   1 (8m28s ago)   40m   10.244.2.6   mokka-vr200-llm-worker3
restarts=1 startedAt=2026-09-23T07:29:14Z ready=true
{"id":"cmpl-847f00a039039c4b",...,"choices":[{"index":0,"text":" Paris. It was founded in 789 AD by Charlemagne,",...,"finish_reason":"length",...}],...,"usage":{"prompt_tokens":5,"total_tokens":21,"completion_tokens":16,...}}
HTTP_STATUS=200 TIME_TOTAL=1.990006s
```

The E2 pods were deleted at 07:37:33Z (`kubectl ... delete pod sglang-xeon-help sglang-xeon-launch`).

## Files

All under `/tmp/vr200-llm-spike-58fc971e/cpu/`:

- Final manifest (live, `kubectl diff` clean): `e1-vllm-cpu.yaml`; earlier attempts
  `e1-vllm-cpu.run1.yaml`, `e1-vllm-cpu.run2.yaml`; client pod `e1-client-pod.yaml`
- Scripts: `e1-apply.sh`, `e1-wait.sh`, `e1-status.sh`, `e1-api.sh`, `e1-platform-probe-light.py`
- E1 evidence: `e1-run1-last-attempt.log`, `e1-run1-describe.txt`, `e1-run1-pod.yaml`,
  `e1-run1-dmesg.txt`, `e1-run2-dmesg.txt`, `e1-wait*.log`, `e1-apply*.log`,
  `e1-run3-vllm.log` (startup log of the serving pod, first container), `e1-platform-probe-light.out`,
  `e1-api.log`, `e1-latency.log`, `e1-nvidia-smi.log`, `e1-reverify-after-e2.log`
- E2 evidence: `e2-sglang-xeon-help.yaml`, `e2-sglang-xeon-launch.yaml`, `e2-help.log`,
  `e2-launch.log`, `e2-launch-describe.txt`, `e2-pods-final.yaml`, `e2-dmesg-global-oom.txt`,
  `e2-start.txt`, `e2-end.txt`
- vLLM v0.30.0 source/docs used for settings (fetched from raw.githubusercontent.com at tag
  v0.30.0): `src-*`; image metadata: `e-vllm-cpu-*.json|txt`

State at the end: I left `deploy/vllm-cpu` (+ Service `vllm-cpu`) and `pod/curl-client`
running at 07:39:43Z. When I next looked (after 07:56Z), the Deployment had been scaled to 0 and
`curl-client` deleted, about 15 minutes earlier. I did neither. INFERENCE: this was the chief's
re-verify-then-scale-down from addendum item 3.

```
$ kubectl --context kind-mokka-vr200-llm -n spike-cpu get events --sort-by=.lastTimestamp
15m   Normal    ScalingReplicaSet   deployment/vllm-cpu              Scaled down replica set vllm-cpu-b4cbd5f5d from 1 to 0
15m   Normal    Killing             pod/curl-client                  Stopping container curl
$ kubectl ... get deploy,svc
deployment.apps/vllm-cpu   0/0     0            0           104m
service/vllm-cpu   ClusterIP   10.96.65.167   <none>        8000/TCP   104m
```

No new OOM kills after 07:36:14 (`dmesg -T | grep 'Killed process' | tail` still ends there).
The one-shot `vllm-serve-help` pod was deleted after capture.
Nothing outside namespace spike-cpu was created or changed. No tracked repo files were
edited, nothing was committed or pushed, and nothing was posted externally.
