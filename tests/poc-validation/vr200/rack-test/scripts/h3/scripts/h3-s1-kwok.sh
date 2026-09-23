#!/bin/bash
# H3 step 1: install KWOK v0.8.0 in-cluster with the stage-fast stages MINUS
# pod-complete (H2 finding F1). Exits non-zero if the controller is not
# Running/Ready, if pod-complete exists, or if any expected stage is missing.
set -uo pipefail
H2="${HOME}/mokka-hetero/h2"
LOG="${HOME}/mokka-hetero/logs/h3-s1-kwok.log"
exec > >(tee "${LOG}") 2>&1

fail=0
echo "start $(date -u +%FT%TZ)"

kubectl apply -f "${H2}/kwok/kwok-v0.8.0.yaml"
rc=$?; echo "apply kwok rc=${rc}"; [[ ${rc} -eq 0 ]] || fail=1

kubectl -n kube-system rollout status deploy/kwok-controller --timeout=300s
rc=$?; echo "rollout rc=${rc}"; [[ ${rc} -eq 0 ]] || fail=1

kubectl apply -f "${H2}/kwok/stage-fast-v0.8.0-no-pod-complete.yaml"
rc=$?; echo "apply stages rc=${rc}"; [[ ${rc} -eq 0 ]] || fail=1

echo "== stages"
kubectl get stages.kwok.x-k8s.io -o name | sort
have="$(kubectl get stages.kwok.x-k8s.io -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort | tr '\n' ' ')"
want="node-heartbeat-with-lease node-initialize pod-delete pod-ready "
if [[ "${have}" != "${want}" ]]; then
  echo "FAIL stages: have='${have}' want='${want}'"; fail=1
else
  echo "PASS stages exactly: ${have}"
fi
if kubectl get stages.kwok.x-k8s.io pod-complete >/dev/null 2>&1; then
  echo "FAIL pod-complete stage exists"; fail=1
else
  echo "PASS pod-complete absent"
fi

echo "== kwok-controller"
kubectl -n kube-system get deploy kwok-controller -o wide
kubectl -n kube-system get pods -l app=kwok-controller -o wide
phase="$(kubectl -n kube-system get pods -l app=kwok-controller -o jsonpath='{range .items[*]}{.status.phase}/{.status.containerStatuses[0].ready}/{.status.containerStatuses[0].restartCount} {end}')"
echo "controller phase/ready/restarts: ${phase}"
if [[ "${phase}" != "Running/true/0 " ]]; then
  echo "FAIL controller not exactly one Running/ready pod with 0 restarts"; fail=1
fi
kubectl -n kube-system get deploy kwok-controller -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
echo "== controller log (tail)"
kubectl -n kube-system logs deploy/kwok-controller --tail=20

echo "DONE fail=${fail} $(date -u +%FT%TZ)"
exit "${fail}"
