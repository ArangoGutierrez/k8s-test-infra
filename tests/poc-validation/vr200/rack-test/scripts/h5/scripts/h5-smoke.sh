#!/bin/bash
# Smoke test: can a pause-image pod holding one vr200-x1 claim reach Running on
# a real VR200 worker (DRA plugin prepares, CDI hooks run) and on a KWOK tray
# (pod-ready stage)? Also shows the claim/pod status fields the checker reads.
set -uo pipefail
LOG="${HOME}/mokka-hetero/logs/h5-smoke.log"
exec > >(tee "${LOG}") 2>&1
echo "start $(date -u +%FT%TZ)"
for n in mokka-hetero-worker8 kwok-vr200-00; do
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: smoke-${n}
  namespace: sched-test
  labels: {mokka-hetero.nvidia.com/scenario: smoke}
spec:
  terminationGracePeriodSeconds: 0
  nodeSelector: {kubernetes.io/hostname: ${n}}
  tolerations: [{key: kwok.x-k8s.io/node, operator: Exists, effect: NoSchedule}]
  containers:
  - name: app
    image: registry.k8s.io/pause:3.10
    imagePullPolicy: IfNotPresent
    resources: {claims: [{name: gpu}]}
  resourceClaims: [{name: gpu, resourceClaimTemplateName: vr200-x1}]
EOF
done
for i in $(seq 1 45); do
  s="$(kubectl -n sched-test get pods -l mokka-hetero.nvidia.com/scenario=smoke -o json | jq -r '[.items[] | "\(.metadata.name)=\(.status.phase)"] | join(" ")')"
  echo "t+$((i*2))s ${s}"
  [[ "$(grep -o Running <<<"${s}" | wc -l)" == "2" ]] && break
  sleep 2
done
kubectl -n sched-test get pods -o wide
kubectl -n sched-test get pods -o json | jq -c '.items[] | {name: .metadata.name, node: .spec.nodeName, phase: .status.phase, rcs: .status.resourceClaimStatuses, cs: [.status.containerStatuses[]? | {ready, state: (.state|keys)}]}'
kubectl -n sched-test get resourceclaims -o json | jq -c '.items[] | {name: .metadata.name, owner: [.metadata.ownerReferences[]? | {kind, name}], results: .status.allocation.devices.results, reservedFor: [.status.reservedFor[]?.name]}'
kubectl -n sched-test get events --sort-by=.lastTimestamp | tail -15
kubectl -n sched-test delete pods -l mokka-hetero.nvidia.com/scenario=smoke --wait=false
for i in $(seq 1 60); do
  p="$(kubectl -n sched-test get pods --no-headers 2>/dev/null | wc -l)"; c="$(kubectl -n sched-test get resourceclaims --no-headers 2>/dev/null | wc -l)"
  [[ "${p}" == "0" && "${c}" == "0" ]] && { echo "cleanup done after ~$((i*2))s: pods=0 claims=0"; break; }
  sleep 2
done
echo "after: pods=$(kubectl -n sched-test get pods --no-headers 2>/dev/null | wc -l) claims=$(kubectl get resourceclaims -A --no-headers 2>/dev/null | wc -l)"
echo "DONE $(date -u +%FT%TZ)"
