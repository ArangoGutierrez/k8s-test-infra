#!/bin/bash
# H7 k4: TAS objects. Server dry-run first (covers the CRD CEL rules H6 could
# not check offline, Risk 4), then H6's surviving CEL mutant k4-m3.yaml
# (dra-gpu dropped from coveredResources) must be REJECTED by the same dry-run,
# then apply and wait for the ClusterQueues to go Active.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
LOG="${HOME}/mokka-hetero/logs/h7-k4-tas-objects.log"
mkdir -p "$(dirname "${LOG}")"
exec > >(tee "${LOG}") 2>&1
echo "start $(date -u +%FT%TZ)"
fail=0

# A server dry-run does not create the Namespace, so the namespaced objects
# would fail NotFound (first run, 17:35Z). Create only the Namespace first.
kubectl create namespace mokka-hetero-kueue --dry-run=client -o yaml | kubectl apply -f -
kubectl apply --dry-run=server -f k4-tas-objects.yaml
rc=$?; echo "k4 server dry-run rc=${rc}"; [[ ${rc} -eq 0 ]] || { echo "FAIL k4 dry-run"; exit 1; }

kubectl apply --dry-run=server -f k4-m3.yaml > /tmp/h7-k4-m3.out 2>&1
rc=$?; echo "k4-m3 (mutant) server dry-run rc=${rc}"; grep -iE 'invalid|denied|error' /tmp/h7-k4-m3.out
[[ ${rc} -ne 0 ]] && echo "PASS mutant k4-m3 rejected by the server" || { echo "FAIL mutant k4-m3 accepted"; fail=1; }

kubectl apply -f k4-tas-objects.yaml
rc=$?; echo "k4 apply rc=${rc}"; [[ ${rc} -eq 0 ]] || exit 1

for cq in vr200 gb300 h100; do
  kubectl wait --for=condition=Active "clusterqueues.kueue.x-k8s.io/${cq}" --timeout=60s
  rc=$?; [[ ${rc} -eq 0 ]] && echo "PASS ClusterQueue ${cq} Active" || { echo "FAIL ClusterQueue ${cq} not Active"; fail=1; }
done
kubectl get topologies.kueue.x-k8s.io,resourceflavors.kueue.x-k8s.io,clusterqueues.kueue.x-k8s.io
kubectl -n mokka-hetero-kueue get localqueues.kueue.x-k8s.io,resourceclaimtemplates
kubectl get topologies.kueue.x-k8s.io mokka-hetero-rack -o jsonpath='{.spec.levels}{"\n"}'
echo "DONE fail=${fail} $(date -u +%FT%TZ)"
exit "${fail}"
