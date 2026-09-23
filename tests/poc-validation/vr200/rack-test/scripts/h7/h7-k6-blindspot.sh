#!/bin/bash
# H7 k6: design (b)'s blind spot, recorded on the live cluster (H6 F-A1/F-A2 context).
# A plain pod outside Kueue takes the 4 Rubin devices of kwok-vr200-00 through DRA.
#   hidden : the pod requests NO accounting resource. Kueue TAS still counts the
#            tray as free (it subtracts only the non-TAS pods' REQUESTS,
#            tas_flavor_snapshot.go:260-265), so tas-a is expected to be admitted
#            with one pod stuck Pending on a DRA allocation failure.
#   visible: the same pod also requests tas-vr200-gpu: 4. TAS is expected to refuse
#            tas-a with "allows to fit only 17 out of 18 pod(s)".
# Own namespace (not Kueue-managed, frameworks=batch/job only); KWOK tray only.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
LOG="${HOME}/mokka-hetero/logs/h7-k6-blindspot.log"
exec > >(tee "${LOG}") 2>&1
NS=mokka-hetero-kueue
BNS=mokka-hetero-kueue-blind
RES=mokka-hetero.nvidia.com/tas-vr200-gpu
echo "start $(date -u +%FT%TZ)"
fail=0
pass() { echo "PASS $*"; }
bad() { echo "FAIL $*"; fail=1; }

wl() { kubectl -n "${NS}" get workloads.kueue.x-k8s.io -o json | jq -c '[.items[] | select(any(.metadata.ownerReferences[]?; .kind=="Job" and .name=="tas-a"))] | first // {} | [(.status.conditions // [])[] | select(.type=="QuotaReserved" or .type=="Admitted") | "\(.type)=\(.status) \(.reason): \(.message)"]'; }

blind_pod() { # $1 = hidden|visible
  local resources
  if [[ "$1" == visible ]]; then
    resources="      requests:
        ${RES}: \"4\"
      limits:
        ${RES}: \"4\""
  else
    resources=""
  fi
  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: blindspot-tray
  namespace: ${BNS}
  labels:
    mokka-hetero.nvidia.com/scenario: kueue-blindspot
spec:
  nodeSelector:
    kubernetes.io/hostname: kwok-vr200-00
  tolerations:
  - key: kwok.x-k8s.io/node
    operator: Exists
    effect: NoSchedule
  terminationGracePeriodSeconds: 0
  containers:
  - name: app
    image: registry.k8s.io/pause:3.10
    imagePullPolicy: IfNotPresent
    resources:
${resources}
      claims:
      - name: gpus
  resourceClaims:
  - name: gpus
    resourceClaimTemplateName: vr200-x4
EOF
}

setup_blind() { # $1 variant
  blind_pod "$1" | kubectl apply -f -
  kubectl -n "${BNS}" wait --for=condition=Ready pod/blindspot-tray --timeout=60s
  kubectl -n "${BNS}" get resourceclaims -o json | jq -r '.items[] | "blind claim \(.metadata.name): \([.status.allocation.devices.results[]? | "\(.pool)/\(.device)"] | join(","))"'
  kubectl -n "${BNS}" get pod blindspot-tray -o jsonpath='blind pod node={.spec.nodeName} tas-request={.spec.containers[0].resources.requests}{"\n"}'
}

teardown_a() {
  kubectl -n "${NS}" delete job tas-a --wait=true --ignore-not-found
  for _ in $(seq 1 30); do
    [[ "$(kubectl -n "${NS}" get pods -o name | wc -l)" -eq 0 && "$(kubectl -n "${NS}" get resourceclaims -o name | wc -l)" -eq 0 ]] && break; sleep 2
  done
  echo "after teardown: pods=$(kubectl -n "${NS}" get pods -o name | wc -l) claims=$(kubectl -n "${NS}" get resourceclaims -o name | wc -l)"
}

kubectl create namespace "${BNS}" --dry-run=client -o yaml | kubectl apply -f -
# The vr200-x4 template from k4, moved to the blind-spot namespace.
kubectl -n "${NS}" get resourceclaimtemplate vr200-x4 -o json |
  jq --arg ns "${BNS}" '{apiVersion, kind, metadata: {name: .metadata.name, namespace: $ns}, spec}' | kubectl apply -f -

echo "== variant hidden (no accounting request)"
setup_blind hidden
kubectl apply -f k5-job-a.yaml
sleep 25
echo "tas-a workload: $(wl)"
kubectl -n "${NS}" get pods -l mokka-hetero.nvidia.com/kueue-job=tas-a -o json > /tmp/h7-k6-hidden-pods.json
jq -r '"tas-a pods=\(.items|length) running=\([.items[]|select(.status.phase=="Running")]|length) pending=\([.items[]|select(.status.phase=="Pending")]|length)"' /tmp/h7-k6-hidden-pods.json
jq -r '.items[] | select(.status.phase!="Running") | "not running: \(.metadata.name) phase=\(.status.phase) node=\(.spec.nodeName // "-") hostnameSelector=\(.spec.nodeSelector["kubernetes.io/hostname"] // "-") gates=\(.spec.schedulingGates // [] | length)"' /tmp/h7-k6-hidden-pods.json
for p in $(jq -r '.items[] | select(.status.phase!="Running") | .metadata.uid' /tmp/h7-k6-hidden-pods.json); do
  kubectl -n "${NS}" get events --field-selector "involvedObject.uid=${p},reason=FailedScheduling" -o json | jq -r '.items[-1] | "event \(.reason) count=\(.count // .series.count // 1): \(.message)"'
done
[[ "$(wl)" == *'Admitted=True'* ]] && pass "hidden: Kueue admitted tas-a although one tray is held outside Kueue" || bad "hidden: tas-a not admitted: $(wl)"
[[ "$(jq '[.items[]|select(.status.phase=="Running")]|length' /tmp/h7-k6-hidden-pods.json)" -eq 17 && \
   "$(jq -r '[.items[]|select(.status.phase=="Pending")|.spec.nodeSelector["kubernetes.io/hostname"]]|join(",")' /tmp/h7-k6-hidden-pods.json)" == "kwok-vr200-00" ]] \
  && pass "hidden: 17 Running, the 1 Pending pod is the one TAS pinned to kwok-vr200-00" || bad "hidden: unexpected pod states"
teardown_a
kubectl -n "${BNS}" delete pod blindspot-tray --wait=true

echo "== variant visible (the blind pod also requests ${RES}: 4)"
setup_blind visible
kubectl apply -f k5-job-a.yaml
for _ in $(seq 1 30); do [[ "$(wl)" == *'QuotaReserved=False'*'fit'* ]] && break; sleep 3; done
echo "tas-a workload: $(wl)"
[[ "$(wl)" == *'allows to fit only 17 out of 18 pod(s)'* ]] && pass "visible: TAS refuses tas-a, 17 of 18 fit" || bad "visible: unexpected: $(wl)"
[[ "$(kubectl -n "${NS}" get pods -o name | wc -l)" -eq 0 ]] && pass "visible: tas-a created no pods" || bad "visible: tas-a has pods"
teardown_a
kubectl delete namespace "${BNS}" --wait=true
echo "left: ns ${BNS} $(kubectl get ns "${BNS}" -o name 2>&1 | tail -1); claims on kwok-vr200 pools: $(kubectl get resourceclaims -A -o json | jq '[.items[].status.allocation.devices.results[]? | select(.pool|startswith("kwok-vr200-"))] | length')"
echo "DONE fail=${fail} $(date -u +%FT%TZ)"
exit "${fail}"
