# Task H8 report: ComputeDomain on the 3 real VR200 workers (design B-1)

Status: **DONE_WITH_CONCERNS** (2026-09-23 15:49Z-17:41Z; Teleport expired 17:20Z and
was renewed by the user; I resumed at 17:31Z).

Summary:
- The upstream DRA v0.5.0 ComputeDomain loop runs end to end on the 3 real VR200
  workers, with real `nvidia-imex --nogpu`:
  - C1, C2, C3, C5 PASS (c4 run at 16:51Z);
  - C4' and C6' (the DNS-names-mode checks) PASS in c4b (GREEN, 17:32:27Z, fail=0);
  - c4b mutation check: 5 single-fact mutants, all KILLED, survived=0.
- Concerns:
  - F-H8-1: the CD plugin CrashLoops on all 6 h100/gb300 workers (mock driver
    versions are below the IMEXDaemonsWithDNSNames minimum). As a result, DRA release
    rev 2 is `failed` (helm --wait timeout). The chief decided: no feature-gate
    change, no rollback.
  - F-H8-2: H6's C4 ("domain UP") and C6 ("left UP") cannot work in this mode.
    C4 FAILs on a working domain and C6's first half passed vacuously. They are
    replaced by C4'/C6' in c4b.
  - c5 was skipped (chief decision, F-H8-1).

## Results after renewal (17:31Z-17:41Z)

### Step 1: F-H8-1 evidence

```
$ helm history nvidia-dra-driver -n nvidia        (17:31:12Z)
1  Wed Sep 23 10:13:38 2026  deployed  dra-driver-nvidia-gpu-0.5.0  0.5.0  Install complete
2  Wed Sep 23 16:49:19 2026  failed    dra-driver-nvidia-gpu-0.5.0  0.5.0  Upgrade "nvidia-dra-driver" failed: resource DaemonSet/nvidia/dra-driver-nvidia-gpu-kubelet-plugin not ready. status: InProgress, message: Available: ...
nvml-mock-h100 / gb300 / vr200: 2  deployed  Upgrade complete
```
c2 log end (`h8-c2-enable-cd.log`):
```
Error: UPGRADE FAILED: resource DaemonSet/nvidia/dra-driver-nvidia-gpu-kubelet-plugin not ready. status: InProgress, message: Available: 3/9
context deadline exceeded
helm upgrade nvidia-dra-driver rc=1
```
Crash lines, h100 node (`kubectl -n nvidia logs dra-driver-nvidia-gpu-kubelet-plugin-5gxsb -c compute-domains --previous`, mokka-hetero-worker):
```
I0923 17:26:56.736556 device_state.go:918] Minimum required version: 570.158.01
E0923 17:26:56.747865 device_state.go:931] IMEXDaemonsWithDNSNames feature requires GPU driver version >= 570.158.1, but found 550.163.1
E0923 17:26:56.747881 device_state.go:932] If installed via helm, set featureGates.IMEXDaemonsWithDNSNames=false to disable
Error: error creating driver: driver version validation failed: minimum version not satisfied for IMEXDaemonsWithDNSNames feature
```
gb300 node (`...-j5698`, mokka-hetero-worker4):
```
I0923 17:31:07.533935 device_state.go:918] Minimum required version: 570.158.01
E0923 17:31:07.546971 device_state.go:931] IMEXDaemonsWithDNSNames feature requires GPU driver version >= 570.158.1, but found 570.124.6
Error: error creating driver: driver version validation failed: minimum version not satisfied for IMEXDaemonsWithDNSNames feature
```
Plugin container states (17:31Z):
```
worker7  compute-domains:ready=true,restarts=0,started 16:49:24Z  gpus:ready=true,restarts=0
worker8  compute-domains:ready=true,restarts=0,started 16:49:24Z  gpus:ready=true,restarts=0
worker9  compute-domains:ready=true,restarts=0,started 16:49:23Z  gpus:ready=true,restarts=0
worker, worker2, worker3 (h100), worker4, worker5, worker6 (gb300):
         compute-domains:ready=false,restarts=12-13,state=CrashLoopBackOff  gpus:ready=true,restarts=0
```

### Step 2: how the original c4 ended (confirms the earlier INFERENCE)

```
FAIL C4 domain status DEGRADED
PASS C4 3 nodes READY NO_GPU
PASS C5 ComputeDomain Ready (necessary, not sufficient)
cdb52c63-....00000000-0000-0000-0000-000000000001.32766 mokka-hetero-worker7=Ready,mokka-hetero-worker8=Ready,mokka-hetero-worker9=Ready
PASS C5 clique ... holds worker7..9 Ready
PASS C5 vr200-cd-workload-8599db97cb-{hfg8z,lcwz7,qc2kk} channel0 is a char device with mock major 255
pod "computedomain-daemon-...-glvnr" deleted from nvidia namespace
PASS C6 domain left UP after peer loss (status=DEGRADED)    <- vacuous: it was DEGRADED before the delete
FAIL C6 domain did not recover                               <- UP is unreachable with 3 of 18 slots
PASS real L4 has no compute apps
DONE fail=1 2026-09-23T17:10:17Z
```

### Step 3a: c4b GREEN (as written, sha256 1a6e6a05...ca77a669, log `h8-c4b-GREEN.log`)

```
start 2026-09-23T17:31:54Z channel major=255
...-hcj4g: {"status":"DEGRADED","ready":["0=compute-domain-daemon-0000/NO_GPU","1=compute-domain-daemon-0001/NO_GPU","2=compute-domain-daemon-0002/NO_GPU"],"unavailable":15,"total":18}
PASS C4' ...-hcj4g: 3 READY NO_GPU pairwise CONNECTED, 15 UNAVAILABLE of 18 slots, status DEGRADED
PASS C4' ...-z77xz: (same)
PASS C4' ...-zg725: (same)
 Nodes From\To  0   1   2   3 ... 17
       0        C   C   C   N ... N
       1        C   C   C   N ... N
       2        C   C   C   N ... N
Domain State: DEGRADED
PASS C5 ComputeDomain Ready (necessary, not sufficient)
PASS C5 clique cdb52c63-a444-456b-bc5a-682dd9718bb7.00000000-0000-0000-0000-000000000001.32766 holds worker7..9 Ready
PASS C5 vr200-cd-workload-8599db97cb-hfg8z channel0 'character special file ff 0' (mock major 255)
PASS C5 vr200-cd-workload-8599db97cb-lcwz7 channel0 'character special file ff 0' (mock major 255)
PASS C5 vr200-cd-workload-8599db97cb-qc2kk channel0 'character special file ff 0' (mock major 255)
READY before=3
deleting pod/computedomain-daemon-...-z77xz at 17:32:12
PASS C6' READY dropped to 2 after peer loss (17:32:15)
PASS C6' READY back to 3 after the DaemonSet replaced the daemon (17:32:25)
(new worker9 daemon ...-wb5f6 1/1 Running)
PASS no real node has nvidia.com/gpu.clique
PASS real-tier GPU devices 48
12x NVIDIA GB300 NVL|Blackwell
12x NVIDIA Graphics Device|Rubin
24x NVIDIA H100 80GB HBM3|Hopper
compute-domain slices on: mokka-hetero-worker7,mokka-hetero-worker8,mokka-hetero-worker9
checked /dev/nvidia* on all kind nodes          (no FAIL line = 0 entries on all 10 nodes)
PASS no kind node container restarted           (StartedAt vs the 16:48Z before-file)
L4 compute apps: pid                            (header only)
PASS real L4 has no compute apps
DONE fail=0 2026-09-23T17:32:27Z
```

### Step 3b: c4b mutation check (`c4b-mutants.sh`, log `h8-c4b-mutants.log`)

Each mutant is a copy with exactly one expected fact changed. The script prints the
diff and asserts it is 1 line. M1-M3 and M5 skip C6' (RUN_C6=0); M4 keeps C6' but
never deletes the peer.
```
start 2026-09-23T17:35:46Z subject sha256 1a6e6a05066375aa
== M1-ready-3to4:     42c42  [[ "${r}" -eq 3 && ...  ->  [[ "${r}" -eq 4 && ...
FAIL C4' ...-hcj4g: ready=3 unavailable=15 total=18 status=DEGRADED pairwise=true   (x3 daemons)
KILLED M1-ready-3to4 rc=1
== M2-unavail-15to14: 42c42  "${u}" -eq 15  ->  "${u}" -eq 14
FAIL C4' ... ready=3 unavailable=15 total=18 ... (x3)
KILLED M2-unavail-15to14 rc=1
== M3-clique-32766to0: 17c17  WANT_CLIQUE="...0001.32766"  ->  "...0001.0"
FAIL C5 clique objects: cdb52c63-....00000000-0000-0000-0000-000000000001.32766 mokka-hetero-worker7=Ready,...
KILLED M3-clique-32766to0 rc=1
== M4-c6-no-delete:   65c65  kubectl -n "${DRV}" delete "${d9}" --wait=false  ->  true # M4: peer NOT deleted
FAIL C6' READY stayed 3 with a peer deleted
KILLED M4-c6-no-delete rc=1
== M5-pairwise-CONNECTED: 41c41  all(.=="CONNECTED")  ->  all(.=="NEVER_CONNECTED")
FAIL C4' ... pairwise=false (x3)
KILLED M5-pairwise-CONNECTED rc=1
DONE survived=0 2026-09-23T17:40:45Z
```
Each mutant reddened ONLY its own guard. For example, M5's post-checks (17:40:45Z) still
show PASS for clique label, 48 devices, node restarts and L4.
Guards NOT independently mutation-checked: C6' "back to 3" (it passes trivially in M4;
its GREEN evidence is the drop to 2 followed by the return to 3); the /dev/nvidia* leak
check (the H1 pattern, not re-mutated here); the per-pod channel0 major (only via GREEN).

Note: the ComputeDomain workload holds 12 Rubin devices (3 claims x 4 on worker7..9) plus 3
channel claims, and 3 daemon claims live in `nvidia`. The chief observed 6 claims in
mokka-hetero-cd and 3 in nvidia, which matches.

Final-state evidence is the M5 run's post-checks at 17:40:45Z (above) plus the M4 run's
C6' "back to 3" at 17:40:27Z.

## Historical: results before the Teleport expiry (kept for the record)

At 17:25Z tsh asked for a browser SSO login; I stopped that call without logging in
and resumed after the user renewed.

## Results after GO (16:48Z-16:54Z)

### c2 (enable CD), log `~/mokka-hetero/logs/h8-c2-enable-cd.log`

```
start 2026-09-23T16:48:03Z
(10 node containers, all StartedAt 2026-09-23T10:10:57Z, RestartCount 0)
L4 compute apps before: pid            <- header only
IMEX channel major=255 caps major=256
helm upgrade nvml-mock-h100 rc=0   (REVISION 2)   daemon set "nvml-mock-h100" successfully rolled out
helm upgrade nvml-mock-gb300 rc=0  (REVISION 2)   daemon set "nvml-mock-gb300" successfully rolled out
helm upgrade nvml-mock-vr200 rc=0  (REVISION 2)   daemon set "nvml-mock-vr200" successfully rolled out
PASS mokka-hetero-worker  proc-devices='255 nvidia-caps-imex-channels;256 nvidia-caps;' channel0=ff 0 DeviceFileMinor: 512
... identical PASS line for worker2..worker9 (9/9)
== c) DRA driver: ComputeDomains on
```
The DRA `helm upgrade --wait` was still waiting at 16:50Z. **Its final rc and the
c2 post-checks were never read** (Teleport expired first). INFERENCE: it failed at the
300s timeout (~16:54Z) because of F-H8-1, which leaves release `nvidia-dra-driver` rev 2
in status `failed` with its resources applied. c2 exits at that point, so its
invariants (48 devices, no clique label, /dev/nvidia* = 0, StartedAt, L4 after)
did NOT run.

Kubelet-plugin pods at 16:50:29Z (`kubectl -n nvidia get pods -o wide`):
```
dra-driver-nvidia-gpu-controller-6bb8f84cc6-nprfc   1/1  Running           0            mokka-hetero-control-plane
dra-driver-nvidia-gpu-kubelet-plugin-9nwl8          2/2  Running           0            mokka-hetero-worker7
dra-driver-nvidia-gpu-kubelet-plugin-mqjz5          2/2  Running           0            mokka-hetero-worker8
dra-driver-nvidia-gpu-kubelet-plugin-9sndk          2/2  Running           0            mokka-hetero-worker9
dra-driver-nvidia-gpu-kubelet-plugin-5gxsb          1/2  CrashLoopBackOff  3 (28s ago)  mokka-hetero-worker   (h100)
... same 1/2 CrashLoopBackOff on worker2, worker3 (h100) and worker4, worker5, worker6 (gb300)
```
On the crashing pods: `compute-domains ready=false restarts=3 last=1` and `gpus ready=true restarts=0`.

worker7 CD plugin (VR200) confirms H6's clique inference:
```
nvlib.go:354] identified fabric clique UUID/ID (device 0/GPU-307f0000-0000-0000-0000-000000000000): 00000000-0000-0000-0000-000000000001/32766
... devices 1, 2, 3: same UUID/ID
```

**F-H8-1 (new): the DRA v0.5.0 ComputeDomain plugin refuses to start on the h100 and gb300 profiles.**
```
E0923 16:50:07.786160 device_state.go:931] IMEXDaemonsWithDNSNames feature requires GPU driver version >= 570.158.1, but found 550.163.1
E0923 16:50:07.786173 device_state.go:932] If installed via helm, set featureGates.IMEXDaemonsWithDNSNames=false to disable
Error: error creating driver: driver version validation failed: minimum version not satisfied for IMEXDaemonsWithDNSNames feature
(gb300 pod j5698: "... but found 570.124.6")
```
The mock profiles' driver versions (h100 550.163.01, gb300 570.124.06) are below
the CD minimum of 570.158.01; vr200 (615.23) passes. Mokka fidelity question: a real
GB300 NVL system needs a newer branch than 570.124 (UNVERIFIED).
Consequences:
- c5 (VR200 + GB300 in one CD) cannot run as-is.
- The `nvidia-dra-driver` release cannot reach Ready with CD on unless either
  `featureGates.IMEXDaemonsWithDNSNames=false` is set or the gb300/h100 profile
  driver versions are raised.

### c4 (C1-C6 as drafted), log `~/mokka-hetero/logs/h8-c4-cd-check.log`

```
start 2026-09-23T16:51:08Z channel major=255
L4 compute apps before: pid     <- header only
ComputeDomain uid=cdb52c63-a444-456b-bc5a-682dd9718bb7
deployment "vr200-cd-workload" successfully rolled out
PASS C1 pods on mokka-hetero-worker7,mokka-hetero-worker8,mokka-hetero-worker9
PASS C1 3 claims with 4 GPUs from the pod's node
PASS C2 3 daemon pods Ready
PASS C2 computedomain-daemon-cdb52c63-...-glvnr CLIQUE_ID=00000000-0000-0000-0000-000000000001.32766
PASS C2 computedomain-daemon-cdb52c63-...-hcj4g CLIQUE_ID=00000000-0000-0000-0000-000000000001.32766
PASS C2 computedomain-daemon-cdb52c63-...-zg725 CLIQUE_ID=00000000-0000-0000-0000-000000000001.32766
PASS C3 ...-glvnr -q READY
PASS C3 ...-hcj4g -q READY
PASS C3 ...-zg725 -q READY
== C4 IMEX domain: UP, 3 nodes READY, version NO_GPU   <- still looping at 16:54:18Z
```
The pods were placed at 16:51:04Z (workload pods 1/1 Running on worker7/8/9, daemons
1/1 Running on worker7/8/9 with pod IPs 10.244.8.28 / .5.24 / .6.27).

**F-H8-2 (new): C4 "domain UP" cannot be reached in the v0.5.0 default mode, and C6 as
drafted is vacuous.** Direct probe from the worker7 daemon (`...-zg725`) at 16:54:32Z:
```
$ kubectl -n nvidia exec <d7> -c compute-domain-daemon -- nvidia-imex-ctl -c /imexd/imexd.cfg -N -j
{"timestamp":"9/23/2026 16:54:29.117","status":"DEGRADED"}      (nodes omitted)
nodes: "0","1","2" status READY version NO_GPU; "3".."17" UNAVAILABLE version ""
node 0 connections: 0 CONNECTED, 1 CONNECTED, 2 CONNECTED, 3 NEVER_CONNECTED
$ ... -N
Node #0   - compute-domain-daemon-0000 - READY                - Version: NO_GPU
Node #1   * compute-domain-daemon-0001 *  - READY             - Version: NO_GPU
Node #2   - compute-domain-daemon-0002 - READY                - Version: NO_GPU
Node #3 .. #17 - compute-domain-daemon-0003..0017 - UNAVAILABLE
 Nodes From\To  0   1   2   3 ...
       0        C   C   C   N ...
       1        C   C   C   N ...
       2        C   C   C   N ...
       3..17    I   I   I   I ...
Domain State: DEGRADED
imexd.cfg: IMEX_NODE_CONFIG_FILE=/imexd/nodes.cfg, SERVER_PORT=50000, IMEX_WAIT_FOR_QUORUM=RECOVERY
daemon log: "Attempting connection for target node 6 - compute-domain-daemon-0006:50000, attempt #161" (every 60s, nodes 3..17)
```
Interpretation (source for the 18: `MAX_NODES_PER_IMEX_DOMAIN` env in
templates/compute-domain-daemon.tmpl.yaml:39-40; the 18 DNS slots are observed
above): with IMEXDaemonsWithDNSNames=true each daemon's nodes.cfg lists 18 DNS slots.
3 daemons fill 3 slots, so the domain is DEGRADED, never UP.
- What this DOES prove: 3 real `nvidia-imex --nogpu` daemons on the 3 VR200 workers
  are READY with version NO_GPU and pairwise CONNECTED over the pod network (the full
  3x3 block is C).
- H6's C4 asserts `.status == "UP"`, so it goes red on a working domain.
- H6's C6 tests "left UP" with `!= "UP"`. Starting from DEGRADED, that passes
  immediately without any peer loss (theater). Its "back UP" step can never pass.

INFERENCE about the c4 run I could not observe: it kept running under nohup, and its
C6 deleted the worker9 daemon pod (the DaemonSet replaces it) and then timed out
waiting for UP, ending `DONE fail=1`. Unverified: read `~/mokka-hetero/logs/h8-c4-cd-check.log`.

### c4b (corrected C4'/C5/C6' + c2 post-checks): written at this point [SUPERSEDED: run GREEN and mutation-checked at 17:32-17:41Z, see top]

`/tmp/mokka-hetero-58fc971e/h8/c4b-cd-check-dns.sh` (`bash -n` ok; not uploaded, since
the scp was waiting on the SSO login). It asserts, from every daemon's view:
- exactly 3 READY NO_GPU nodes, pairwise CONNECTED, 15 UNAVAILABLE of 18, status DEGRADED;
- C5 as in c4 (CD Ready, one clique object with worker7..9 Ready, channel0 = char dev major ff);
- C6': the READY count on worker7 drops below 3 after worker9's daemon is deleted, then returns to 3;
- all of c2's post-checks (48 devices plus a per-type breakdown, no clique label,
  /dev/nvidia* on all nodes, node StartedAt vs the before file, L4 empty).

Not mutation-checked. Before relying on it, planned mutants: WANT ready=4, and a
C6' with no delete (must go red).

### Checks NOT done because of the expiry [SUPERSEDED: all done after renewal, see top; c5 skipped by chief decision]
- C5 (CD Ready, the clique object, channel0 major in the pods): not observed.
- C6 (corrected): not run.
- c2 invariants after the DRA upgrade (48 devices, no clique label, /dev/nvidia*
  = 0, StartedAt unchanged): not observed.
- L4 compute apps after: not observed (the last read at 16:51:08Z was header only).
- c5: not run (blocked by F-H8-1 anyway).

## Chief decision received after the expiry (read 17:27Z)

The chief approved: let helm --wait time out, run c2's post-checks separately and c4 on
VR200; skip c5; do NOT change featureGates; do NOT roll back. Record for F-H8-1:
- the exact CrashLoopBackOff lines for one h100 and one gb300 node (recorded above from
  16:50:29Z; re-capture after renewal);
- `helm history nvidia-dra-driver -n nvidia` showing rev 2 "failed" (NOT yet observed);
- the plugin state on worker7/8/9 (2/2 Running at 16:50:29Z; re-capture).

I could not act on it:
```
$ tsh status   (17:27:10Z)
  Logged in as:       <user>@<corp>
  Cluster:            <teleport-proxy>
  Valid until:        2026-09-23 19:20:24 +0200 CEST [EXPIRED]
```
Per the brief I did not re-login.

## Next steps once Teleport is renewed (in order) [DONE 17:31-17:41Z]
1. `cat ~/mokka-hetero/logs/h8-c4-cd-check.log ~/mokka-hetero/logs/h8-c2-enable-cd.log | tail`;
   `helm history nvidia-dra-driver -n nvidia`; `nvidia-smi --query-compute-apps=pid --format=csv`.
2. `tsh scp c4b-cd-check-dns.sh` and run it (about 5 min).
3. The chief decides on F-H8-1 (set IMEXDaemonsWithDNSNames=false, leave it, or roll back).

## Prep phase (before GO)

Scope in this phase (ADDENDUM 15:50Z): step 0 (rollback baseline), endpoint
reachability, c1 (overlay build + kind load). No helm upgrade and no cluster
change other than `kind load` until the chief sends GO.

VM scripts and logs: `~/mokka-hetero/h8/` and `~/mokka-hetero/logs/h8-*` on
<vm>. Local copies: `/tmp/mokka-hetero-58fc971e/h8/` (H6 originals
kept as `*.h6orig`).

Script checksums (local == VM, `sha256sum` / `shasum -a 256`, 16:46Z):
```
876da9f7...c61fb00  c1-build-overlay.sh
3f92b9fc...d9bffbb  c2-enable-cd.sh
995fe0ea...b8580e   c3-cd-vr200.yaml   (unchanged from H6)
187d2608...eeabfa   c4-cd-check.sh
eb051d65...f189ae   c5-cd-mixed.yaml   (unchanged from H6)
```

## Pre-flight (15:50Z)

```
$ tsh ssh <user>@<vm> 'date -u; helm list -A; free -m; uptime; nvidia-smi --query-compute-apps=pid --format=csv'
Wed Sep 23 03:50:06 PM UTC 2026
nvidia-dra-driver	nvidia   	1	2026-09-23 10:13:38 UTC	deployed	dra-driver-nvidia-gpu-0.5.0	0.5.0
nvml-mock-gb300  	mokka    	1	...	deployed	nvml-mock-0.4.0-rc1	550.163.01
nvml-mock-h100   	mokka    	1	...	deployed	nvml-mock-0.4.0-rc1	550.163.01
nvml-mock-vr200  	mokka    	1	...	deployed	nvml-mock-0.4.0-rc1	550.163.01
Mem: 15363 total, 10105 available
load average: 4.04, 3.22, 2.27
pid            <- header only: no compute apps on the real L4
rc=0
```

Release name confirmed: `nvidia-dra-driver` (namespace `nvidia`), matching c2.

## Step 0: rollback baseline (DONE)

Script `p0-baseline-endpoints.sh`, log `~/mokka-hetero/logs/h8-p0-baseline-endpoints.log`.
Saved to `~/mokka-hetero/h8/baseline/`: for each release `*.user-values.yaml`,
`*.all-values.yaml`, `*.manifest.yaml` (all `helm get` rc=0).

```
--- nvidia/nvidia-dra-driver
REVISION 1  Wed Sep 23 10:13:38 2026  deployed  dra-driver-nvidia-gpu-0.5.0  Install complete
user-supplied values:
gpuResourcesEnabledOverride: true
nvidiaDriverRoot: /var/lib/nvml-mock/driver
resources:
  computeDomains:
    enabled: false
--- mokka/nvml-mock-h100   REVISION 1 deployed nvml-mock-0.4.0-rc1
  controlPlane.enabled=true (image mokka-control-plane:hetero, Never), gpu.profile=h100,
  image nvml-mock:hetero Never, nodeSelector nvml-mock/profile=h100
--- mokka/nvml-mock-gb300  REVISION 1 deployed: gpu.profile=gb300, image nvml-mock:hetero Never, nodeSelector gb300
--- mokka/nvml-mock-vr200  REVISION 1 deployed: gpu.profile=vr200, image nvml-mock:hetero Never, nodeSelector vr200
```

Running DRA image (all 9 kubelet-plugin pods):
```
nvcr.io/nvidia/dra-driver-nvidia-gpu:v0.5.0@sha256:9b46984c0eb18def60e2b9817b874275f4b5b08d12d491de4f1a7b91b51d706c
```

## Endpoint reachability (DONE, all reachable)

```
curl -sI https://registry-1.docker.io/v2/ -> http=401 rc=0
curl -sI https://auth.docker.io/token -> http=405 rc=0
curl -sI https://production.cloudflare.docker.com/ -> http=403 rc=0
curl -sI https://nvcr.io/v2/ -> http=401 rc=0
curl -sI http://archive.ubuntu.com/ubuntu/dists/jammy/InRelease -> http=200 rc=0
curl -sI http://security.ubuntu.com/ubuntu/dists/jammy-security/InRelease -> http=200 rc=0
curl -sI https://proxy.golang.org/ -> http=200 rc=0
curl -sI https://sum.golang.org/latest -> http=200 rc=0
jammy-updates nvidia-imex-595 595.91.07-0ubuntu0.22.04.1
jammy-security nvidia-imex-595 595.91.07-0ubuntu0.22.04.1
```
From inside a kind node (for the busybox:1.36 pull at c4 time):
```
$ docker exec mokka-hetero-worker7 curl -sI -m 10 -o /dev/null -w "%{http_code}\n" https://registry-1.docker.io/v2/
401   rc=0
```
busybox is NOT on worker6..9 yet (`crictl images` shows only pause:3.10); the
kubelet will pull it at c4 time.

## c1: overlay build + kind load (DONE)

Log `~/mokka-hetero/logs/h8-c1-build-overlay.log` (start 15:59:31Z, DONE 16:00:32Z).

```
base (from worker7 CRI): nvcr.io/nvidia/dra-driver-nvidia-gpu@sha256:9b46984c0eb18def60e2b9817b874275f4b5b08d12d491de4f1a7b91b51d706c
pull base rc=0
#9 ... Get:4 http://archive.ubuntu.com/ubuntu jammy-updates/multiverse amd64 nvidia-imex-595 amd64 595.91.07-0ubuntu0.22.04.1
#9 ... Setting up nvidia-imex-595 (595.91.07-0ubuntu0.22.04.1) ...
#7 [shim 1/6] FROM docker.io/library/golang:1.26.8@sha256:6c2a5538...
build rc=0
== image gates
nvidia-imex-ctl -h rc=1
Usage: nvidia-imex-ctl [-c <nvidia-imex config.cfg path>] <-n|-N|-q> [-j][-H]
ld.so --list /usr/bin/nvidia-imex.real rc=0   (libpthread, libdl, libc, librt, libz, libm all resolved; no "not found")
ld.so --list /usr/bin/nvidia-imex-ctl rc=0    (same set, all resolved)
-rwxr-xr-x 2424460  /usr/bin/nvidia-imex        (shim, built 16:00)
-rwxr-xr-x 9600776  /usr/bin/nvidia-imex-ctl
-rwxr-xr-x 17290368 /usr/bin/nvidia-imex.real
file gate rc=0
nvidia-imex.real --help rc=0
save rc=0
kind load rc=0
mokka-hetero-control-plane .. mokka-hetero-worker9 (10 nodes): docker.io/library/dra-driver-nvidia-gpu-imex-nogpu:v0.5.0-mokka 9ad02c0d30fda
DONE 2026-09-23T16:00:32Z
```
Docker image id `sha256:b22ac7339fb4...` (477590177 B, created 16:00:06Z).

**Defect found in H6's c1 file gate:** busybox `command -v a b c d` only reports
the first name, and the rc does not reflect the others. Proof (overlay image):
```
command -v compute-domain-daemon no-such-binary -> "/usr/bin/compute-domain-daemon", multi-arg rc=0
```
Re-checked per binary:
```
compute-domain-daemon rc=0, compute-domain-kubelet-plugin rc=0, gpu-kubelet-plugin rc=0,
compute-domain-controller rc=0, no-such-binary-positive-control rc=127
```
H6's `grep -qi 'usage\|imex'` help-text gate would also have matched
"nvidia-imex-ctl: error while loading shared libraries". H8 added the
`ld.so --list` gate, which reports "not found" for any missing library.

## F-B4: host majors and the chosen mock majors (read-only, render only)

Host `/proc/devices` (character devices, nvidia entries plus neighbours):
```
195 nvidia / nvidia-modeset / nvidiactl
234 nvidia-nvlink
235 nvidia-caps
236 nvidia-caps-imex-channels      <- the real 595 driver registers it (F-B4 is real)
240..254 in use (nvme-generic .. gpiochip), 261 accel, 509 media
510 nvidia-uvm
511 nvidia-nvswitch
```
c2's `pick()` over the same file gives **channel major 255, caps major 256**. Neither
appears in the host's character or block list. worker7 shows the same nvidia
lines (shared kernel).
INFERENCE: 255 and 256 are outside the kernel's dynamic char ranges (234-254,
384-511), so a later module load should not claim them.

## Render of what c2 will change (client-side `helm template`, no cluster write)

Script `p1-render-diff.sh`, log `~/mokka-hetero/logs/h8-p1-render-diff.log`.
- nvml-mock-{h100,gb300,vr200}: the only diff against the installed manifest is 4 env vars
  on the DaemonSet: `IMEX_MOCK_CHANNELS=true`, `IMEX_CHANNEL_COUNT=2048`,
  `IMEX_CHANNEL_MAJOR=255`, `IMEX_CAPS_MAJOR=256`.
- nvidia-dra-driver: object kinds go from (DaemonSet 1, DeviceClass 3) to (DaemonSet 1,
  Deployment 1, DeviceClass 5). The image `dra-driver-nvidia-gpu-imex-nogpu:v0.5.0-mokka`
  goes on the gpus container, the compute-domains container and the controller.
  `ALT_PROC_DEVICES_PATH=/alt-proc-devices` comes from hostPath
  `/var/lib/nvml-mock/imex/proc-devices`. The kubelet-plugin keeps its required
  nodeAffinity on `feature.node.kubernetes.io/pci-10de.present`. The controller
  prefers control-plane and tolerates only control-plane/master/CriticalAddonsOnly,
  so it cannot land on a tainted KWOK node.
- Consequence: the kubelet-plugin pods restart on all 9 real workers (image change).

## Source checks behind c2/c4 (dra-driver v0.5.0 @90b3a591, Mokka 29cc7971)

- Plugin log line: `nvlib.go:354 "identified fabric clique UUID/ID (device %d/%s): %s/%s"`.
- Daemon container name `compute-domain-daemon`; label key `resource.nvidia.com/computeDomain`
  (templates/compute-domain-daemon.tmpl.yaml:31, cmd/compute-domain-daemon/common.go:32).
- Config `/imexd/imexd.cfg` (cmd/compute-domain-daemon/main.go:45-46).
- ComputeDomainClique lives in the driver namespace (cdclique.go:67,210) and is named
  `<cdUID>.<cliqueID>` (cdclique.go:171-173). Its `.daemons[].status` enum is Ready/NotReady.
- `-N -j` shape `.nodes[].status/.version` with `NO_GPU`: matches Mokka's run.sh:494-500.
- The GPU slice pool name equals the node name (`gpu.nvidia.com pool=mokka-hetero-worker7 devs=4`);
  9 nodes carry `nvml-mock/profile` (3 h100, 3 gb300, 3 vr200; worker9 is back on vr200).
- All three profiles have `fabric.state: auto` with cluster UUID `...0001`, clique 0 (h100, gb300)
  or 32766 (vr200). Strict mode refuses to start if the state is not COMPLETED (nvlib.go:317-326).
  INFERENCE (H6): `auto` resolves to COMPLETED in the plugin container. If it does not, the
  compute-domains containers fail and c2's `--wait` goes red; rollback is below.

## H8 changes to H6's c2/c4 (besides renaming h6 to h8 in log and tmp paths)

- c2: node-container StartedAt/RestartCount before and after (cmp); a change means FAIL and a
  reminder to run `s3b-hide-host-gpu.sh --restart`. L4 compute apps are listed before and
  after, and any app is a FAIL. After the DRA upgrade it waits up to 120s for
  48 GPU devices and 9 compute-domain slice nodes before asserting.
- c4: `cd "$(dirname "$0")"` so c3 resolves; workload rollout timeout 300s -> 600s; L4 check
  before and after.
- `bash -n` passes locally and on the VM; `shellcheck -S warning` passes on c1/c2/c4.

## State at PREP DONE (16:10-16:46Z, read-only)

```
node containers: all 10 StartedAt 2026-09-23T10:10:57Z restarts=0
kubectl get resourceclaims -A -> No resources found (0)
namespaces: default detect-vllm kube-node-lease kube-public kube-system local-path-storage mokka nvidia sched-test
nvidia-smi --query-compute-apps=pid --format=csv -> "pid" (header only)
```

## Rollback commands (to be run only if the chief decides)

```
helm rollback nvidia-dra-driver 1 -n nvidia --wait --timeout 300s
for r in h100 gb300 vr200; do helm rollback nvml-mock-${r} 1 -n mokka --wait --timeout 300s; done
kubectl delete ns mokka-hetero-cd mokka-hetero-cd-mixed --ignore-not-found
# then verify: 48 gpu.nvidia.com devices, /dev/nvidia* = 0 on all 10 nodes, L4 compute apps empty
```

## Cluster state left in place (last observation 17:40:45Z)

- nvml-mock-{h100,gb300,vr200}: rev 2 deployed (IMEX simulator on, majors 255/256).
- nvidia-dra-driver: rev 2 `failed` (observed in helm history at 17:31:12Z; CD on, overlay image,
  altProcDevices; the --wait timeout, F-H8-1). The CD containers on the 6 h100/gb300 workers are in CrashLoopBackOff;
  the gpus containers there were ready.
- Namespace `mokka-hetero-cd`: ComputeDomain `vr200-cd` (uid cdb52c63-a444-456b-bc5a-682dd9718bb7),
  Deployment `vr200-cd-workload` (3 pods, 12 Rubin devices held on worker7..9), 3 daemons in `nvidia`
  (worker9's daemon is `...-wb5f6` after C6'; M4 did not delete it).
- No rollback done and no feature-gate change (chief decision). The rollback commands are above.
- Local log copies: `/tmp/mokka-hetero-58fc971e/h8/logs/`.
