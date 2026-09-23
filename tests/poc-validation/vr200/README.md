# vr200 proof of concept: vLLM / SGLang and a heterogeneous rack test

Artifacts from a 2026-09-23 proof of concept on Mokka's `vr200` (Vera-Rubin)
preview profile from PR #872. Nothing here is wired into CI; the scripts are
spike tooling kept for reproduction and reference.

## Layout

| Path | What |
|---|---|
| `llm-demo/` | Runnable bundle (`run.sh up | vllm | sglang | vllm-serve`): how far the unmodified vLLM v0.30.0 and SGLang v0.5.20 images get on a kind cluster simulating VR200, with checks that fail on drift. See its README. |
| `spike/` | Reports from the engine spike: platform (A), NVML/CUDA surface map (B), vLLM ladder (C), SGLang ladder (D), CPU serving control (E), and a cancelled libcuda-mock probe (F). |
| `rack-test/REPORT.md` | Summary of the heterogeneous rack test and all findings. Start here. |
| `rack-test/SPEC.md` | The test design. |
| `rack-test/reports/` | Per-task evidence (H1 real tier, H2 drafts, H3 KWOK tier and racks, H4 vLLM detection through DRA, H5 scheduling scenarios, H6 Kueue/ComputeDomain research, H7 Kueue TAS, H8 ComputeDomain). |
| `rack-test/scripts/h1..h8/` | The scripts, manifests and checkers those tasks ran. |

## Environment assumptions

- Mokka source: upstream `main` plus the four commits of PR #872 (vr200
  profile). `llm-demo/run.sh` and the rack scripts read it from `MOKKA_SRC`.
- The rack test ran on a single x86 VM (4 CPUs, 15 GB) reached over Teleport;
  hostnames, users and local paths are replaced with `<vm>`, `<user>`,
  `<repo>` and `~`. Scripts refer to run-scoped scratch directories under
  `/tmp/` and to `~/mokka-hetero/` on the VM; adjust them before reuse.
- Images used: `vllm/vllm-openai:v0.30.0`, `lmsysorg/sglang:v0.5.20`,
  `vllm/vllm-openai-cpu:v0.30.0`, `dra-driver-nvidia-gpu` chart 0.5.0,
  KWOK v0.8.0, Kueue v0.19.5.

## Headline results

- VR200 is identified as Rubin, compute capability 10.7, by the DRA driver and
  by vLLM's own platform code, distinct from GB300 (Blackwell 10.0).
- Scheduling on 64 nodes / 336 simulated GPUs (1/3 H100, 1/3 GB300, 1/3 VR200,
  one full 18-tray VR200 rack): type targeting, no spill, rack locality, Kueue
  TAS rack placement and a ComputeDomain across real VR200 nodes all pass their
  checks, and the checks were shown to fail under mutation.
- Findings for Mokka, the DRA driver and Kueue are listed in
  `rack-test/REPORT.md`.
