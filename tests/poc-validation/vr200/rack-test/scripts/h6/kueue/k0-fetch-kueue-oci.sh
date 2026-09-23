#!/bin/bash
# H6 Kueue step 0, HOST side (any machine that reaches registry.k8s.io; the
# VM does not: every *.pkg.dev host resets, H3 1a). Builds a single-platform
# linux/amd64 OCI image-layout tar of the OFFICIAL Kueue v0.19.5 image, every
# byte checked against the Kubernetes image promoter's pin:
#   kubernetes/k8s.io registry.k8s.io/images/k8s-staging-kueue/images.yaml
#   "sha256:a55949705d7ab1fe38034da56c5af95deecec3da0abebb209a372f7a5c414a2d": ["v0.19.5"]
# H3's gcr.io staging route does not exist for Kueue: its promoter source is
# us-central1-docker.pkg.dev/k8s-staging-images/kueue (promoter-manifest.yaml:3-4),
# and gcr.io/k8s-staging-kueue answers 401 anonymously while
# gcr.io/k8s-staging-kwok answers 200 (H6 report).
#
# The index.json descriptor carries io.containerd.image.name, which is the
# name `ctr images import` (used by `kind load image-archive`) gives the image
# (containerd v2.3.1 client/import.go:275-279), so the chart's
# registry.k8s.io/kueue/kueue:v0.19.5 + IfNotPresent resolves to it.
#
# Output: ${OUT_DIR}/kueue-v0.19.5-amd64.oci.tar and a .sha256 next to it.
# Needs: bash, curl, python3. No Docker.
set -uo pipefail
OUT_DIR="${OUT_DIR:-$(cd "$(dirname "$0")" && pwd)}"
PIN="sha256:a55949705d7ab1fe38034da56c5af95deecec3da0abebb209a372f7a5c414a2d"
NAME="registry.k8s.io/kueue/kueue:v0.19.5"
REG="https://registry.k8s.io/v2/kueue/kueue"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/h6-kueue-oci.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
echo "start $(date -u +%FT%TZ) work=${WORK}"

sha() { python3 -c 'import hashlib,sys; print("sha256:"+hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }
get() { # $1 url path suffix, $2 out file, $3 Accept
  local code
  code="$(curl -sSL --max-time 300 -o "$2" -w '%{http_code}' -H "Accept: $3" "${REG}/$1")"
  [[ "${code}" == "200" ]] || { echo "FAIL GET $1 http=${code}"; exit 1; }
}

# 1. the promoter pin, fetched fresh
curl -sS --max-time 30 -o "${WORK}/images.yaml" \
  https://raw.githubusercontent.com/kubernetes/k8s.io/main/registry.k8s.io/images/k8s-staging-kueue/images.yaml \
  || { echo "FAIL promoter fetch"; exit 1; }
grep -qF "\"${PIN}\": [\"v0.19.5\"]" "${WORK}/images.yaml" || { echo "FAIL promoter does not pin v0.19.5 to ${PIN}"; exit 1; }
echo "PASS promoter pins v0.19.5 to ${PIN}"

# 2. the index by that digest; its raw bytes must hash to the pin
get "manifests/${PIN}" "${WORK}/index.raw" 'application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json'
got="$(sha "${WORK}/index.raw")"
[[ "${got}" == "${PIN}" ]] || { echo "FAIL index sha ${got} != ${PIN}"; exit 1; }
echo "PASS index bytes hash to the pin"
read -r MT DG SZ < <(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
m=[m for m in d["manifests"] if m["platform"]["os"]=="linux" and m["platform"]["architecture"]=="amd64"]
assert len(m)==1, m
print(m[0]["mediaType"], m[0]["digest"], m[0]["size"])' "${WORK}/index.raw")
echo "linux/amd64 child: ${DG} (${MT}, ${SZ} bytes)"

# 3. the amd64 manifest, then config and layers, each checked by digest and size
mkdir -p "${WORK}/oci/blobs/sha256"
blob() { # $1 digest $2 size
  local f="${WORK}/oci/blobs/sha256/${1#sha256:}"
  get "blobs/$1" "${f}" '*/*'
  [[ "$(sha "${f}")" == "$1" ]] || { echo "FAIL blob $1 hash"; exit 1; }
  [[ "$(wc -c < "${f}" | tr -d ' ')" == "$2" ]] || { echo "FAIL blob $1 size"; exit 1; }
}
get "manifests/${DG}" "${WORK}/oci/blobs/sha256/${DG#sha256:}" "${MT}"
[[ "$(sha "${WORK}/oci/blobs/sha256/${DG#sha256:}")" == "${DG}" ]] || { echo "FAIL manifest hash"; exit 1; }
[[ "$(wc -c < "${WORK}/oci/blobs/sha256/${DG#sha256:}" | tr -d ' ')" == "${SZ}" ]] || { echo "FAIL manifest size"; exit 1; }
n=0
while read -r d s; do blob "${d}" "${s}"; n=$((n + 1)); done < <(python3 -c '
import json,sys
m=json.load(open(sys.argv[1]))
print(m["config"]["digest"], m["config"]["size"])
for l in m["layers"]: print(l["digest"], l["size"])' "${WORK}/oci/blobs/sha256/${DG#sha256:}")
echo "PASS manifest + ${n} blobs (config and layers) verified by sha256 and size"

# 4. OCI layout: index.json names the image the way containerd import reads it
printf '{"imageLayoutVersion":"1.0.0"}' > "${WORK}/oci/oci-layout"
python3 - "${WORK}/oci/index.json" "${MT}" "${DG}" "${SZ}" "${NAME}" <<'PY'
import json,sys
out,mt,dg,sz,name=sys.argv[1:]
json.dump({"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json",
  "manifests":[{"mediaType":mt,"digest":dg,"size":int(sz),
    "platform":{"os":"linux","architecture":"amd64"},
    "annotations":{"io.containerd.image.name":name,"org.opencontainers.image.ref.name":"v0.19.5"}}]},
  open(out,"w"))
PY
TAR="${OUT_DIR}/kueue-v0.19.5-amd64.oci.tar"
tar -C "${WORK}/oci" -cf "${TAR}" oci-layout index.json blobs || { echo "FAIL tar"; exit 1; }
tsha="$(sha "${TAR}")"
echo "${tsha#sha256:}  kueue-v0.19.5-amd64.oci.tar" > "${TAR}.sha256"
echo "${DG}" > "${OUT_DIR}/kueue-v0.19.5-amd64.manifest-digest"
ls -la "${TAR}"
echo "tar ${tsha}; amd64 manifest ${DG}"
echo "DONE $(date -u +%FT%TZ)"
