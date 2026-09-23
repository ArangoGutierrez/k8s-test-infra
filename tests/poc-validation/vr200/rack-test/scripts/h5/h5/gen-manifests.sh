#!/bin/bash
# Derive H5's scenario manifests from H2's drafts. Only three mechanical
# changes: namespace mokka-hetero-sched -> sched-test; the busybox image (not
# present on any node, the VM pulls are unreliable) -> registry.k8s.io/pause:3.10,
# which every kind node already has; the `command:` line is dropped because
# pause needs none. Plus two naive templates for S1b (not type-exclusive on
# purpose) and the S1b Deployments. Prints a diff per derived file.
set -euo pipefail
H2="${1:?usage: gen-manifests.sh <h2-dir> <out-dir>}"
OUT="${2:?}"
mkdir -p "${OUT}"
xf() { sed -e 's/mokka-hetero-sched/sched-test/g' \
           -e 's#^\( *\)image: busybox:1.36$#\1image: registry.k8s.io/pause:3.10\n\1imagePullPolicy: IfNotPresent#' \
           -e '/command: \["sleep", "86400"\]/d' "$1"; }

xf "${H2}/dra/claim-templates.yaml" > "${OUT}/00-templates.yaml"
cat >> "${OUT}/00-templates.yaml" <<'EOF'
---
# S1b only: NAIVE selector, memory == 288Gi. Matches GB300 and VR200 (both 288Gi).
apiVersion: resource.k8s.io/v1
kind: ResourceClaimTemplate
metadata:
  name: vr200-naive-mem
  namespace: sched-test
spec:
  spec:
    devices:
      requests:
      - name: gpu
        exactly:
          deviceClassName: gpu.nvidia.com
          selectors:
          - cel:
              expression: >-
                device.capacity['gpu.nvidia.com'].memory.compareTo(quantity('288Gi')) == 0
---
# S1b only: NAIVE selector, compute capability major 10. Matches GB300 (10.0) and VR200 (10.7).
apiVersion: resource.k8s.io/v1
kind: ResourceClaimTemplate
metadata:
  name: vr200-naive-cc10
  namespace: sched-test
spec:
  spec:
    devices:
      requests:
      - name: gpu
        exactly:
          deviceClassName: gpu.nvidia.com
          selectors:
          - cel:
              expression: >-
                device.attributes['gpu.nvidia.com'].cudaComputeCapability.major() == 10
EOF
xf "${H2}/scenarios/s1-type-targeting.yaml" > "${OUT}/s1.yaml"
xf "${H2}/scenarios/s2-fill.yaml"          > "${OUT}/s2-fill.yaml"
xf "${H2}/scenarios/s2-extra.yaml"         > "${OUT}/s2-extra.yaml"
xf "${H2}/scenarios/s3-rack-a.yaml"        > "${OUT}/s3-a.yaml"
xf "${H2}/scenarios/s3-rack-b.yaml"        > "${OUT}/s3-b.yaml"
# S1b: the s1-vr200 Deployment, renamed, 12 replicas, on each naive template.
for sel in mem cc10; do
  awk 'BEGIN{RS="---\n"; ORS=""} /name: s1-vr200/ {print}' "${OUT}/s1.yaml" \
    | sed -e "s/name: s1-vr200/name: s1b-vr200-naive-${sel}/" \
          -e 's/replicas: 4/replicas: 12/' \
          -e 's/scenario: s1$/scenario: s1b/' \
          -e "s/want: vr200/want: vr200-naive-${sel}/" \
          -e "s/resourceClaimTemplateName: vr200-x1/resourceClaimTemplateName: vr200-naive-${sel}/"
  echo "---"
done | sed '$d' > "${OUT}/s1b.yaml"

for p in dra/claim-templates.yaml:00-templates.yaml scenarios/s1-type-targeting.yaml:s1.yaml \
         scenarios/s2-fill.yaml:s2-fill.yaml scenarios/s2-extra.yaml:s2-extra.yaml \
         scenarios/s3-rack-a.yaml:s3-a.yaml scenarios/s3-rack-b.yaml:s3-b.yaml; do
  echo "== diff h2/${p%%:*} -> ${p##*:}"
  diff "${H2}/${p%%:*}" "${OUT}/${p##*:}" | grep -E '^[<>]' | sort | uniq -c || true
done
echo "== s1b.yaml"
cat "${OUT}/s1b.yaml"
