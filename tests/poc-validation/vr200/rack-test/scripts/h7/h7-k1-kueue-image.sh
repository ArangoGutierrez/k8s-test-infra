#!/bin/bash
# H7 k1 (replaces H6's k1-kueue-image.sh, whose staging source is dead):
# gcr.io/k8s-staging-kueue answers 403 to an anonymous token request from the VM
# and 401 from the Mac; the promoter manifest names
# us-central1-docker.pkg.dev/k8s-staging-images/kueue as the source, and the VM
# resets *.pkg.dev. So the image was pulled on the Mac from registry.k8s.io by
# the linux/amd64 child of the promoter-pinned index, saved as an OCI archive,
# and copied here. This script re-verifies the whole chain on the VM before
# loading anything:
#   promoter images.yaml pins v0.19.5 -> index a5594970 (grep)
#   index-raw.json hashes to a5594970 and names amd64 child 6ac15f95
#   the tar's index.json points at 6ac15f95 and blobs/sha256/6ac15f95 hashes to it
#   every blob in the tar hashes to its own name (config and layers included)
#   after kind load, every node's containerd lists the image at 6ac15f95
set -uo pipefail
cd "$(dirname "$0")" || exit 1
LOG="${HOME}/mokka-hetero/logs/h7-k1-kueue-image.log"
mkdir -p "$(dirname "${LOG}")"
exec > >(tee "${LOG}") 2>&1

PROMOTED_INDEX="sha256:a55949705d7ab1fe38034da56c5af95deecec3da0abebb209a372f7a5c414a2d"
OFFICIAL="registry.k8s.io/kueue/kueue:v0.19.5"
TAR="img/kueue-v0.19.5-amd64.tar"
X="$(mktemp -d)"
trap 'rm -rf "${X}"' EXIT

echo "start $(date -u +%FT%TZ)"
curl -sS --max-time 30 -o img/promoter-images-vm.yaml \
  https://raw.githubusercontent.com/kubernetes/k8s.io/main/registry.k8s.io/images/k8s-staging-kueue/images.yaml
rc=$?; echo "promoter fetch (VM) rc=${rc}"; [[ ${rc} -eq 0 ]] || exit 1
grep -nF "\"${PROMOTED_INDEX}\": [\"v0.19.5\"]" img/promoter-images-vm.yaml \
  || { echo "FAIL promoter does not pin kueue v0.19.5 to ${PROMOTED_INDEX}"; exit 1; }
echo "PASS promoter pins v0.19.5 to ${PROMOTED_INDEX}"

got_index="sha256:$(sha256sum img/index-raw.json | cut -d' ' -f1)"
echo "index-raw.json sha256: ${got_index}"
[[ "${got_index}" == "${PROMOTED_INDEX}" ]] || { echo "FAIL index digest mismatch"; exit 1; }
amd64="$(jq -r '.manifests[] | select(.platform.os=="linux" and .platform.architecture=="amd64") | .digest' img/index-raw.json)"
echo "index linux/amd64 child: ${amd64}"
[[ "${amd64}" == sha256:* ]] || { echo "FAIL no linux/amd64 child"; exit 1; }

tar -xf "${TAR}" -C "${X}"
rc=$?; echo "untar rc=${rc}"; [[ ${rc} -eq 0 ]] || exit 1
tar_target="$(jq -r '.manifests[0].digest' "${X}/index.json")"
tar_name="$(jq -r '.manifests[0].annotations["io.containerd.image.name"]' "${X}/index.json")"
echo "tar index.json: target=${tar_target} name=${tar_name} entries=$(jq '.manifests|length' "${X}/index.json")"
[[ "${tar_target}" == "${amd64}" && "${tar_name}" == "${OFFICIAL}" ]] || { echo "FAIL tar index does not point at the amd64 child"; exit 1; }
bad=0; n=0
for b in "${X}"/blobs/sha256/*; do
  n=$((n+1))
  [[ "$(sha256sum "${b}" | cut -d' ' -f1)" == "$(basename "${b}")" ]] || { echo "FAIL blob ${b##*/} content != name"; bad=1; }
done
echo "blobs verified: ${n}, bad=${bad}"
[[ ${bad} -eq 0 ]] || exit 1
cfg="$(jq -r '.config.digest' "${X}/blobs/sha256/${amd64#sha256:}")"
nlayers="$(jq '.layers|length' "${X}/blobs/sha256/${amd64#sha256:}")"
echo "manifest ${amd64}: config=${cfg} layers=${nlayers}"
for d in "${cfg}" $(jq -r '.layers[].digest' "${X}/blobs/sha256/${amd64#sha256:}"); do
  [[ -f "${X}/blobs/sha256/${d#sha256:}" ]] || { echo "FAIL manifest references missing blob ${d}"; exit 1; }
done
echo "PASS the tar holds exactly the manifest, config and ${nlayers} layers the pinned index names"

nodes="$(kind get nodes --name mokka-hetero | sort | paste -sd, -)"
echo "nodes: ${nodes}"
kind load image-archive "${TAR}" --name mokka-hetero --nodes "${nodes}"
rc=$?; echo "kind load rc=${rc}"; [[ ${rc} -eq 0 ]] || exit 1

fail=0
for n in ${nodes//,/ }; do
  line="$(docker exec "${n}" ctr -n k8s.io images ls 2>/dev/null | awk -v img="${OFFICIAL}" '$1==img{print $1, $3}')"
  echo "${n}: ${line:-MISSING}"
  [[ "${line}" == "${OFFICIAL} ${amd64}" ]] || fail=1
done
echo "DONE fail=${fail} $(date -u +%FT%TZ)"
exit "${fail}"
