#!/usr/bin/env bash
# Demo: how far vLLM and SGLang get on a Mokka cluster that simulates
# Vera-Rubin (vr200, NVIDIA/k8s-test-infra PR #872), with no GPU anywhere.
#
#   ./run.sh up          kind cluster (1 control-plane + 3 workers), Mokka vr200,
#                        device plugin. Reuses an existing cluster and release.
#   ./run.sh prepull     pull the engine images onto their nodes (~25 GB, slow)
#   ./run.sh vllm        what vLLM's own code concludes about VR200, and where
#                        `vllm serve` stops
#   ./run.sh sglang      what SGLang's helpers read, and where launch_server stops
#   ./run.sh vllm-serve  vLLM CPU build behind a Service on a VR200 node:
#                        a real /v1/completions answer
#   ./run.sh all         vllm, sglang, vllm-serve in order
#   ./run.sh status | clean | down
#
# Every step checks the values the spike measured and exits non-zero when one
# does not hold, so a run is also a regression check.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER="${CLUSTER:-mokka-vr200-llm}"
CTX="kind-${CLUSTER}"
NS="demo-llm"
MOKKA_SRC="${MOKKA_SRC:?set MOKKA_SRC to a checkout of NVIDIA/k8s-test-infra that contains the vr200 profile (PR 872)}"
MOCK_IMAGE="${MOCK_IMAGE:-nvml-mock:vr200}"
VLLM_IMAGE="docker.io/vllm/vllm-openai:v0.30.0"
SGLANG_IMAGE="docker.io/lmsysorg/sglang:v0.5.20"
VLLM_CPU_IMAGE="docker.io/vllm/vllm-openai-cpu:v0.30.0"

k() { kubectl --context "${CTX}" "$@"; }
say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

FAILS=0
expect() { # expect <log-file> <key> <exact value>
  if grep -qxF "RESULT $2=$3" "$1"; then
    printf '  PASS  %-28s %s\n' "$2" "$3"
  else
    printf '  FAIL  %-28s expected [%s], got [%s]\n' "$2" "$3" \
      "$(grep -m1 "^RESULT $2=" "$1" | cut -d= -f2-)"
    FAILS=$((FAILS + 1))
  fi
}
expect_prefix() { # expect_prefix <log-file> <key> <value prefix>
  if grep -q "^RESULT $2=$3" "$1"; then
    printf '  PASS  %-28s %s...\n' "$2" "$3"
  else
    printf '  FAIL  %-28s expected prefix [%s], got [%s]\n' "$2" "$3" \
      "$(grep -m1 "^RESULT $2=" "$1" | cut -d= -f2-)"
    FAILS=$((FAILS + 1))
  fi
}
verdict() {
  if [ "${FAILS}" -eq 0 ]; then echo "  all checks passed"; else die "${FAILS} check(s) failed"; fi
}

node_for_role() { k get nodes -l "mokka-demo/role=$1" -o jsonpath='{.items[0].metadata.name}'; }

cmd_up() {
  for bin in docker kind kubectl helm; do command -v "${bin}" >/dev/null || die "${bin} not found"; done
  [ -f "${MOKKA_SRC}/deployments/nvml-mock/helm/nvml-mock/profiles/vr200.yaml" ] ||
    die "MOKKA_SRC=${MOKKA_SRC} has no vr200 profile; point it at a checkout of PR #872"

  if kind get clusters 2>/dev/null | grep -qx "${CLUSTER}"; then
    say "cluster ${CLUSTER} exists, reusing it"
  else
    if ! docker image inspect "${MOCK_IMAGE}" >/dev/null 2>&1; then
      say "building ${MOCK_IMAGE} from ${MOKKA_SRC}"
      docker build -t "${MOCK_IMAGE}" -f "${MOKKA_SRC}/deployments/nvml-mock/Dockerfile" "${MOKKA_SRC}"
    fi
    say "creating kind cluster ${CLUSTER}"
    prev_ctx="$(kubectl config current-context 2>/dev/null || true)"
    kind create cluster --name "${CLUSTER}" --config "${HERE}/manifests/kind-config.yaml" --wait 180s
    [ -n "${prev_ctx}" ] && kubectl config use-context "${prev_ctx}" >/dev/null
    if ! kind load docker-image "${MOCK_IMAGE}" --name "${CLUSTER}"; then
      tar="$(mktemp "${TMPDIR:-/tmp}/nvml-mock.XXXXXX")"
      docker save --platform linux/arm64 "${MOCK_IMAGE}" -o "${tar}"
      kind load image-archive "${tar}" --name "${CLUSTER}"
      rm -f "${tar}"
    fi
  fi

  if helm --kube-context "${CTX}" -n mokka status nvml-mock >/dev/null 2>&1; then
    say "Mokka release nvml-mock exists, reusing it"
  else
    say "installing Mokka (gpu.profile=vr200)"
    helm install nvml-mock "${MOKKA_SRC}/deployments/nvml-mock/helm/nvml-mock" \
      --kube-context "${CTX}" --namespace mokka --create-namespace \
      --set gpu.profile=vr200 \
      --set image.repository="${MOCK_IMAGE%%:*}" --set image.tag="${MOCK_IMAGE##*:}" \
      --set image.pullPolicy=Never --wait --timeout 180s
  fi

  say "device plugin (same manifest as the repo's device-plugin guide)"
  k label node --all mokka.nvidia.com/type=sgpu --overwrite >/dev/null
  k apply -f "${HERE}/manifests/device-plugin.yaml"
  k -n kube-system wait --for=condition=ready pod -l name=nvidia-device-plugin-mock --timeout=300s

  say "assigning one worker per role (vllm, sglang, cpu)"
  # bash 3.2 (macOS) has no mapfile.
  local workers=() n
  while IFS= read -r n; do workers+=("${n}"); done < <(k get nodes -o name | grep -- '-worker' | sort)
  [ "${#workers[@]}" -ge 3 ] || die "need 3 worker nodes, found ${#workers[@]}"
  k label "${workers[0]}" mokka-demo/role=vllm --overwrite
  k label "${workers[1]}" mokka-demo/role=sglang --overwrite
  k label "${workers[2]}" mokka-demo/role=cpu --overwrite

  k create namespace "${NS}" --dry-run=client -o yaml | k apply -f - >/dev/null
  k -n "${NS}" create configmap demo-probes --from-file="${HERE}/probes" --dry-run=client -o yaml | k apply -f - >/dev/null

  say "simulated VR200 capacity"
  k get nodes -L mokka-demo/role -o custom-columns='NODE:.metadata.name,ROLE:.metadata.labels.mokka-demo/role,GPUS:.status.allocatable.nvidia\.com/gpu'
}

cmd_prepull() {
  say "pulling engine images onto their nodes (runs in parallel; ~25 GB)"
  local pids=()
  docker exec "$(node_for_role vllm)" crictl pull "${VLLM_IMAGE}" & pids+=($!)
  docker exec "$(node_for_role sglang)" crictl pull "${SGLANG_IMAGE}" & pids+=($!)
  docker exec "$(node_for_role cpu)" crictl pull "${VLLM_CPU_IMAGE}" & pids+=($!)
  local rc=0
  for p in "${pids[@]}"; do wait "${p}" || rc=1; done
  [ "${rc}" -eq 0 ] || die "one or more pulls failed"
}

run_job() { # run_job <job-name> <manifest> <log-file>
  k -n "${NS}" delete job "$1" --ignore-not-found --wait=true >/dev/null
  k apply -f "$2" >/dev/null
  local deadline=$((SECONDS + 900)) s f
  while [ "${SECONDS}" -lt "${deadline}" ]; do
    s="$(k -n "${NS}" get job "$1" -o jsonpath='{.status.succeeded}')"
    f="$(k -n "${NS}" get job "$1" -o jsonpath='{.status.failed}')"
    [ -n "${s}" ] || [ -n "${f}" ] && break
    sleep 5
  done
  k -n "${NS}" logs "job/$1" --tail=-1 > "$3"
  cat "$3"
  [ -n "${s:-}" ] || die "job $1 did not succeed (failed=${f:-timeout})"
}

cmd_vllm() {
  say "vLLM ${VLLM_IMAGE##*:} on a simulated VR200 node"
  local log; log="$(mktemp "${TMPDIR:-/tmp}/vllm-discovery.XXXXXX")"
  run_job vllm-discovery "${HERE}/manifests/vllm-discovery.yaml" "${log}"
  say "checks: what vLLM concludes about the hardware"
  expect "${log}" platform NvmlCudaPlatform
  expect "${log}" device_name_0 "NVIDIA Graphics Device"
  expect "${log}" compute_capability_0 10.7
  expect "${log}" total_memory_bytes_0 309237645312
  expect "${log}" nvlink_fully_connected_0_3 True
  expect "${log}" fp8_supported True
  expect "${log}" nvfp4_cutlass_supported True
  expect "${log}" deep_gemm_supported True
  expect "${log}" trtllm_attention_supported True
  expect "${log}" cuda_context_created False
  say "checks: where vllm serve stops"
  expect_prefix "${log}" serve_config max_num_batched_tokens=
  expect "${log}" serve_stop "RuntimeError: No CUDA GPUs are available"
  expect "${log}" serve_listening 0
  verdict
}

cmd_sglang() {
  say "SGLang ${SGLANG_IMAGE##*:} on a simulated VR200 node"
  local log; log="$(mktemp "${TMPDIR:-/tmp}/sglang-discovery.XXXXXX")"
  run_job sglang-discovery "${HERE}/manifests/sglang-discovery.yaml" "${log}"
  say "checks: what SGLang reads, and where launch_server stops"
  expect "${log}" nvgpu_memory_capacity_mib 294912.0
  expect "${log}" torch_cuda_is_available False
  expect_prefix "${log}" launch_stop "RuntimeError: No accelerator"
  expect "${log}" launch_listening 0
  verdict
}

cmd_vllm_serve() {
  say "vLLM CPU build served behind a Service on a simulated VR200 node"
  k apply -f "${HERE}/manifests/vllm-cpu-serve.yaml"
  echo "  waiting for Ready (the first start downloads ~1 GB of weights)"
  k -n "${NS}" rollout status deploy/vllm-cpu --timeout=900s
  k -n "${NS}" wait --for=condition=Ready pod/client --timeout=120s >/dev/null
  local pod; pod="$(k -n "${NS}" get pods -l app.kubernetes.io/name=vllm-cpu -o jsonpath='{.items[0].metadata.name}')"

  say "the serving pod sees simulated VR200 GPUs"
  k -n "${NS}" exec "${pod}" -c vllm -- nvidia-smi --query-gpu=name,memory.total,compute_cap --format=csv
  local gpus; gpus="$(k -n "${NS}" exec "${pod}" -c vllm -- nvidia-smi -L | grep -c '^GPU ')"

  say "POST /v1/completions through the Service"
  local out code
  out="$(k -n "${NS}" exec client -- curl -s -w '\nHTTP %{http_code}' http://vllm-cpu:8000/v1/completions \
    -H 'Content-Type: application/json' \
    -d '{"model":"Qwen/Qwen2.5-0.5B-Instruct","prompt":"The capital of France is","max_tokens":12,"temperature":0}')"
  echo "${out}"
  code="$(echo "${out}" | tail -1 | awk '{print $2}')"
  local metrics; metrics="$(k -n "${NS}" exec client -- curl -s http://vllm-cpu:8000/metrics | grep -c '^vllm:')"

  say "checks"
  local f; f="$(mktemp "${TMPDIR:-/tmp}/vllm-serve.XXXXXX")"
  { echo "RESULT gpus_seen_in_pod=${gpus}"; echo "RESULT http_status=${code}"
    echo "RESULT has_text=$(echo "${out}" | grep -q '"text":"[^"]' && echo yes || echo no)"
    echo "RESULT vllm_metrics_present=$([ "${metrics}" -gt 0 ] && echo yes || echo no)"; } > "${f}"
  expect "${f}" gpus_seen_in_pod 4
  expect "${f}" http_status 200
  expect "${f}" has_text yes
  expect "${f}" vllm_metrics_present yes
  verdict
}

cmd_status() {
  k get nodes -L mokka-demo/role -o custom-columns='NODE:.metadata.name,ROLE:.metadata.labels.mokka-demo/role,GPUS:.status.allocatable.nvidia\.com/gpu'
  k -n "${NS}" get jobs,deploy,pods 2>/dev/null || true
}

cmd_clean() { k delete namespace "${NS}" --ignore-not-found; }
cmd_down() { kind delete cluster --name "${CLUSTER}"; }

case "${1:-}" in
  up) cmd_up ;;
  prepull) cmd_prepull ;;
  vllm) cmd_vllm ;;
  sglang) cmd_sglang ;;
  vllm-serve) cmd_vllm_serve ;;
  all) cmd_vllm; cmd_sglang; cmd_vllm_serve ;;
  status) cmd_status ;;
  clean) cmd_clean ;;
  down) cmd_down ;;
  *) sed -n '2,19p' "$0"; exit 2 ;;
esac
