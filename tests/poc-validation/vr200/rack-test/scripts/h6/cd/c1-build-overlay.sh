#!/bin/bash
# H6 ComputeDomain step 1: build the DRA driver image the upstream
# ComputeDomain path needs on a GPU-less node, and load it into kind.
#
# The compute-domain-daemon runs `nvidia-imex -c /imexd/imexd.cfg` from PATH
# (dra-driver v0.5.0 cmd/compute-domain-daemon/main.go:49-50,286) and probes it
# with `nvidia-imex-ctl ... -q` (:445). The controller starts the daemon pods
# from its OWN image (controller.yaml:87-88 IMAGE_NAME = the chart image;
# daemonset.go:214). Mokka's overlay adds the real nvidia-imex / nvidia-imex-ctl
# (Ubuntu jammy multiverse nvidia-imex-595) and nvidia-imex-shim, which execs
# the real daemon with --nogpu (deployments/nvml-mock/Dockerfile.compute-domain-daemon:15-24,88-94).
# Its default base is v0.4.1; this build pins the base to the exact v0.5.0 image
# the cluster already runs (digest read from a node).
#
# LOCAL BUILD ONLY: never push this image (it repackages proprietary nvidia-imex).
# Run on the VM from the Mokka tree (~/mokka-hetero/src at de8a00dd, H1).
set -uo pipefail
LOG="${HOME}/mokka-hetero/logs/h6-c1-build-overlay.log"
mkdir -p "$(dirname "${LOG}")" "${HOME}/mokka-hetero/tmp"
exec > >(tee "${LOG}") 2>&1
SRC="${HOME}/mokka-hetero/src"
IMG="dra-driver-nvidia-gpu-imex-nogpu:v0.5.0-mokka"
TAR="${HOME}/mokka-hetero/tmp/dra-imex-nogpu.tar"
echo "start $(date -u +%FT%TZ)"

base="$(docker exec mokka-hetero-worker7 crictl inspecti -o json nvcr.io/nvidia/dra-driver-nvidia-gpu:v0.5.0 | jq -r '.status.repoDigests[] | select(startswith("nvcr.io/nvidia/dra-driver-nvidia-gpu@"))' | head -1)"
echo "base (from worker7 CRI): ${base}"
[[ "${base}" == nvcr.io/nvidia/dra-driver-nvidia-gpu@sha256:* ]] || { echo "FAIL could not read the running DRA image digest"; exit 1; }
docker pull --platform linux/amd64 "${base}"
rc=$?; echo "pull base rc=${rc}"; [[ ${rc} -eq 0 ]] || exit 1

docker build --target daemon \
  --build-arg "COMPUTE_DOMAIN_DAEMON_IMAGE=${base}" \
  --build-arg "GOLANG_VERSION=$("${SRC}/hack/golang-version.sh")" \
  -t "${IMG}" -f "${SRC}/deployments/nvml-mock/Dockerfile.compute-domain-daemon" "${SRC}"
rc=$?; echo "build rc=${rc}"; [[ ${rc} -eq 0 ]] || exit 1

echo "== image gates (the overlay must run on the distroless v0.5.0 base)"
fail=0
docker run --rm --entrypoint /usr/bin/nvidia-imex-ctl "${IMG}" -h > /tmp/h6-imexctl-help.txt 2>&1
echo "nvidia-imex-ctl -h rc=$?"; head -3 /tmp/h6-imexctl-help.txt
grep -qi 'usage\|imex' /tmp/h6-imexctl-help.txt || { echo "FAIL nvidia-imex-ctl does not run in the image"; fail=1; }
docker run --rm --entrypoint /busybox/sh "${IMG}" -c 'ls -la /usr/bin/nvidia-imex /usr/bin/nvidia-imex.real /usr/bin/nvidia-imex-ctl; command -v compute-domain-daemon compute-domain-kubelet-plugin gpu-kubelet-plugin compute-domain-controller'
rc=$?; echo "file gate rc=${rc}"; [[ ${rc} -eq 0 ]] || fail=1
docker run --rm --entrypoint /usr/bin/nvidia-imex.real "${IMG}" --help > /tmp/h6-imex-help.txt 2>&1
echo "nvidia-imex.real --help rc=$? (non-zero is acceptable, missing shared libraries are not)"
grep -i 'error while loading shared libraries' /tmp/h6-imex-help.txt && { echo "FAIL nvidia-imex.real misses libraries on this base"; fail=1; }
(( fail == 0 )) || exit 1

docker save --platform linux/amd64 -o "${TAR}" "${IMG}"
rc=$?; echo "save rc=${rc}"; [[ ${rc} -eq 0 ]] || exit 1
nodes="$(kind get nodes --name mokka-hetero | sort | paste -sd, -)"
kind load image-archive "${TAR}" --name mokka-hetero --nodes "${nodes}"
rc=$?; echo "kind load rc=${rc}"; [[ ${rc} -eq 0 ]] || exit 1
for n in ${nodes//,/ }; do
  docker exec "${n}" crictl images 2>/dev/null | awk -v n="${n}" '$1 ~ /dra-driver-nvidia-gpu-imex-nogpu/ {print n": "$1":"$2" "$3}'
done
echo "DONE $(date -u +%FT%TZ)"
