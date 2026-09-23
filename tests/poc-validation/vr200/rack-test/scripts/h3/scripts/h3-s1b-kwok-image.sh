#!/bin/bash
# H3 step 1b: the VM cannot reach registry.k8s.io's Artifact Registry backend
# (*.pkg.dev resets every connection), so load the official KWOK v0.8.0 image
# into the kind workers from the k8s-staging-kwok project on gcr.io instead.
#
# Provenance: the image promoter copies staging images to registry.k8s.io by
# digest; kubernetes/k8s.io registry.k8s.io/images/k8s-staging-kwok/images.yaml
# pins kwok v0.8.0 to index PROMOTED_INDEX. This script refuses to continue
# unless the staging index has exactly that digest and lists AMD64 as its
# linux/amd64 child. The image is then tagged with its official name so the
# upstream kwok.yaml (image registry.k8s.io/kwok/kwok:v0.8.0, IfNotPresent)
# is applied unchanged.
set -uo pipefail
LOG="${HOME}/mokka-hetero/logs/h3-s1b-kwok-image.log"
exec > >(tee "${LOG}") 2>&1

PROMOTED_INDEX="sha256:6d25aa8fbdfe78845423160bf125b5513f9522e2770981f0945c2a250c2b26f0"
AMD64="sha256:28ee38abba19bd0b89600b1b367c32480da45f1d954c80d14db5fc74feee83f2"
STAGING="gcr.io/k8s-staging-kwok/kwok"
OFFICIAL="registry.k8s.io/kwok/kwok:v0.8.0"
TAR="${HOME}/mokka-hetero/tmp/kwok-v0.8.0-amd64.tar"

echo "start $(date -u +%FT%TZ)"

# 1. the promoter pin, fetched fresh
curl -sS --max-time 30 -o /tmp/h3-kwok-promoter.yaml \
  https://raw.githubusercontent.com/kubernetes/k8s.io/main/registry.k8s.io/images/k8s-staging-kwok/images.yaml
rc=$?; echo "promoter fetch rc=${rc}"; [[ ${rc} -eq 0 ]] || exit 1
pin="$(grep -F '[ "v0.8.0" ]' /tmp/h3-kwok-promoter.yaml | head -1)"
echo "promoter line: ${pin}"
if ! grep -qF "\"${PROMOTED_INDEX}\": [ \"v0.8.0\" ]" /tmp/h3-kwok-promoter.yaml; then
  echo "FAIL promoter does not pin kwok v0.8.0 to ${PROMOTED_INDEX}"; exit 1
fi

# 2. the staging index is that digest and names AMD64 as linux/amd64
raw="$(docker buildx imagetools inspect --raw "${STAGING}@${PROMOTED_INDEX}")"
rc=$?; echo "staging index inspect rc=${rc}"; [[ ${rc} -eq 0 ]] || exit 1
got_index="sha256:$(printf '%s' "${raw}" | sha256sum | cut -d' ' -f1)"
echo "staging index sha256 of raw bytes: ${got_index}"
[[ "${got_index}" == "${PROMOTED_INDEX}" ]] || { echo "FAIL index digest mismatch"; exit 1; }
child="$(printf '%s' "${raw}" | jq -r '.manifests[] | select(.platform.os=="linux" and .platform.architecture=="amd64") | .digest')"
echo "index linux/amd64 child: ${child}"
[[ "${child}" == "${AMD64}" ]] || { echo "FAIL amd64 child mismatch"; exit 1; }

# 3. pull by digest, tag with the official name, save single-platform
docker pull --platform linux/amd64 "${STAGING}@${AMD64}"
rc=$?; echo "pull rc=${rc}"; [[ ${rc} -eq 0 ]] || exit 1
docker tag "${STAGING}@${AMD64}" "${OFFICIAL}"
rc=$?; echo "tag rc=${rc}"; [[ ${rc} -eq 0 ]] || exit 1
mkdir -p "$(dirname "${TAR}")"
docker save --platform linux/amd64 -o "${TAR}" "${OFFICIAL}"
rc=$?; echo "save rc=${rc}"; [[ ${rc} -eq 0 ]] || exit 1
ls -la "${TAR}"

# 4. load into the 9 workers (the controller has no control-plane toleration)
workers="$(kind get nodes --name mokka-hetero | grep -v control-plane | sort | paste -sd, -)"
echo "workers: ${workers}"
kind load image-archive "${TAR}" --name mokka-hetero --nodes "${workers}"
rc=$?; echo "kind load rc=${rc}"; [[ ${rc} -eq 0 ]] || exit 1

fail=0
for n in ${workers//,/ }; do
  line="$(docker exec "${n}" ctr -n k8s.io images ls 2>/dev/null | awk '$1=="registry.k8s.io/kwok/kwok:v0.8.0"{print $1, $3}')"
  echo "${n}: ${line:-MISSING}"
  [[ "${line}" == "registry.k8s.io/kwok/kwok:v0.8.0 ${AMD64}" ]] || fail=1
done
echo "DONE fail=${fail} $(date -u +%FT%TZ)"
exit "${fail}"
