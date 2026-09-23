#!/bin/bash
# H8 prep: step 0 rollback baseline (read-only) + endpoint reachability for c1.
# Touches nothing in the cluster.
set -uo pipefail
OUT="${HOME}/mokka-hetero/h8/baseline"
LOG="${HOME}/mokka-hetero/logs/h8-p0-baseline-endpoints.log"
mkdir -p "${OUT}" "$(dirname "${LOG}")"
exec > >(tee "${LOG}") 2>&1
echo "start $(date -u +%FT%TZ)"

echo "== step 0: helm values + history (rollback baseline)"
for r in nvidia/nvidia-dra-driver mokka/nvml-mock-h100 mokka/nvml-mock-gb300 mokka/nvml-mock-vr200; do
  ns="${r%%/*}"; rel="${r##*/}"
  helm get values "${rel}" -n "${ns}" -o yaml > "${OUT}/${rel}.user-values.yaml"; rc1=$?
  helm get values "${rel}" -n "${ns}" --all -o yaml > "${OUT}/${rel}.all-values.yaml"; rc2=$?
  helm get manifest "${rel}" -n "${ns}" > "${OUT}/${rel}.manifest.yaml"; rc3=$?
  echo "--- ${ns}/${rel} (get values rc=${rc1}, --all rc=${rc2}, manifest rc=${rc3})"
  helm history "${rel}" -n "${ns}"
  echo "user-supplied values:"; cat "${OUT}/${rel}.user-values.yaml"
done
sha256sum "${OUT}"/*.yaml

echo "== running DRA image digest (read-only, worker7 CRI)"
docker exec mokka-hetero-worker7 crictl inspecti -o json nvcr.io/nvidia/dra-driver-nvidia-gpu:v0.5.0 | jq -c '{repoTags: .status.repoTags, repoDigests: .status.repoDigests, size: .status.size}'
echo "== pod images in ns nvidia"
kubectl -n nvidia get pods -o wide
kubectl -n nvidia get pods -o jsonpath='{range .items[*]}{.metadata.name}{" "}{range .status.containerStatuses[*]}{.image}{"@"}{.imageID}{" "}{end}{"\n"}{end}'

echo "== local docker images already present (build cache candidates)"
docker images --format '{{.Repository}}:{{.Tag}} {{.ID}} {{.Size}}' | grep -E 'golang|ubuntu|dra-driver' || echo "(none of golang/ubuntu/dra-driver)"
docker info 2>/dev/null | grep -iE 'proxy|mirror|storage driver|driver-type|Default Runtime' || true

echo "== endpoint reachability (curl -sI, 10s timeout)"
for u in \
  https://registry-1.docker.io/v2/ \
  https://auth.docker.io/token \
  https://production.cloudflare.docker.com/ \
  https://nvcr.io/v2/ \
  http://archive.ubuntu.com/ubuntu/dists/jammy/InRelease \
  http://security.ubuntu.com/ubuntu/dists/jammy-security/InRelease \
  https://proxy.golang.org/ \
  https://sum.golang.org/latest ; do
  code="$(curl -sI -m 10 -o /dev/null -w '%{http_code}' "${u}")"; rc=$?
  echo "curl -sI ${u} -> http=${code} rc=${rc}"
done
echo "== apt package presence in jammy multiverse (nvidia-imex-595)"
curl -s -m 30 http://archive.ubuntu.com/ubuntu/dists/jammy-updates/multiverse/binary-amd64/Packages.gz | gunzip 2>/dev/null | awk '/^Package: nvidia-imex-595$/{p=1} p&&/^Version:/{print "jammy-updates nvidia-imex-595 " $2; exit}'
curl -s -m 30 http://security.ubuntu.com/ubuntu/dists/jammy-security/multiverse/binary-amd64/Packages.gz | gunzip 2>/dev/null | awk '/^Package: nvidia-imex-595$/{p=1} p&&/^Version:/{print "jammy-security nvidia-imex-595 " $2; exit}'

echo "== host kernel nvidia majors (F-B4 context)"
grep -iE 'nvidia' /proc/devices
echo "== load"
free -m; uptime
echo "== real-L4 compute apps (must be header only)"
nvidia-smi --query-compute-apps=pid --format=csv
echo "DONE $(date -u +%FT%TZ)"
