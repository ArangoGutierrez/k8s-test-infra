#!/bin/bash
# H6 Kueue step 1, VM side: load the official Kueue v0.19.5 image into the kind
# nodes from the OCI tar k0-fetch-kueue-oci.sh built on a host that reaches
# registry.k8s.io. The VM cannot pull it itself: registry.k8s.io sends manifest
# requests to *.pkg.dev, which resets (H3 1a), and Kueue has no gcr.io staging
# repo (gcr.io/k8s-staging-kueue answers 401; its promoter source is
# us-central1-docker.pkg.dev/k8s-staging-images/kueue).
#
# Copy first, from the host that ran k0 (Teleport needs the sandbox off there):
#   tsh scp kueue-v0.19.5-amd64.oci.tar kueue-v0.19.5-amd64.oci.tar.sha256 \
#     <user>@<vm>:~/mokka-hetero/h6/kueue/
#
# Exact refs:
#   chart image      registry.k8s.io/kueue/kueue:v0.19.5 (the only image the
#                    chart renders with values-kueue.yaml; pullPolicy IfNotPresent)
#   promoted index   sha256:a55949705d7ab1fe38034da56c5af95deecec3da0abebb209a372f7a5c414a2d
#   linux/amd64      sha256:6ac15f950a8e904f994ccfa3bfe71a1a4129a09654ee5c3be1a492e329f03a11
set -uo pipefail
cd "$(dirname "$0")" || exit 1
LOG="${HOME}/mokka-hetero/logs/h6-k1-kueue-image.log"
mkdir -p "$(dirname "${LOG}")"
exec > >(tee "${LOG}") 2>&1
NAME="registry.k8s.io/kueue/kueue:v0.19.5"
AMD64="sha256:6ac15f950a8e904f994ccfa3bfe71a1a4129a09654ee5c3be1a492e329f03a11"
TAR="kueue-v0.19.5-amd64.oci.tar"
echo "start $(date -u +%FT%TZ)"

sha256sum -c "${TAR}.sha256"
rc=$?; echo "tar sha256 check rc=${rc}"; [[ ${rc} -eq 0 ]] || exit 1
idx="$(tar -xOf "${TAR}" index.json)"
echo "index.json: ${idx}"
[[ "$(jq -r '.manifests[0].digest' <<< "${idx}")" == "${AMD64}" && \
   "$(jq -r '.manifests[0].annotations["io.containerd.image.name"]' <<< "${idx}")" == "${NAME}" ]] \
  || { echo "FAIL index.json does not name ${NAME} at ${AMD64}"; exit 1; }
echo "PASS index.json names ${NAME} at ${AMD64}"

# The manager Deployment has no tolerations (chart render), so it can only land
# on untainted real nodes; loading all 10 costs ~60 MB each.
nodes="$(kind get nodes --name mokka-hetero | sort | paste -sd, -)"
kind load image-archive "${TAR}" --name mokka-hetero --nodes "${nodes}"
rc=$?; echo "kind load rc=${rc}"; [[ ${rc} -eq 0 ]] || exit 1

fail=0
for n in ${nodes//,/ }; do
  line="$(docker exec "${n}" ctr -n k8s.io images ls 2>/dev/null | awk -v img="${NAME}" '$1==img{print $1, $3}')"
  echo "${n}: ${line:-MISSING}"
  [[ "${line}" == "${NAME} ${AMD64}" ]] || fail=1
done
echo "DONE fail=${fail} $(date -u +%FT%TZ)"
exit "${fail}"
