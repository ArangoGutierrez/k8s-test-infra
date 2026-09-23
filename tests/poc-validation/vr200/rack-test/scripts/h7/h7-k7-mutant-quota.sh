#!/bin/bash
# H7 k7 mutation (H6 probe mutant M2 on the live cluster): ClusterQueue vr200
# quota 144 -> 72 for both resources. With room for only one rack, "tas-b
# waits" becomes a quota fact, and T3 must go RED because its message is no
# longer the topology one. T1 (19 pods = 76 > 72) is expected RED for the same
# reason. Then the quota is restored from k4 and k7 must be GREEN again.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
L="${HOME}/mokka-hetero/logs"
LOG="${L}/h7-k7-mutant-quota.log"
exec > >(tee "${LOG}") 2>&1
echo "start $(date -u +%FT%TZ)"
quotas() { kubectl get clusterqueues.kueue.x-k8s.io vr200 -o json | jq -c '[.spec.resourceGroups[0].flavors[0].resources[] | {(.name): .nominalQuota}] | add'; }
cp "${L}/h7-k7-tas-check.log" "${L}/h7-k7-green1.log"

echo "== mutant: quota 72"
kubectl patch clusterqueues.kueue.x-k8s.io vr200 --type=json -p '[
  {"op":"replace","path":"/spec/resourceGroups/0/flavors/0/resources/0/nominalQuota","value":"72"},
  {"op":"replace","path":"/spec/resourceGroups/0/flavors/0/resources/1/nominalQuota","value":"72"}]'
echo "quotas now: $(quotas)"
bash h7-k7-tas-check.sh > /dev/null 2>&1; mrc=$?
cp "${L}/h7-k7-tas-check.log" "${L}/h7-k7-mutant-quota72.log"
echo "k7 on mutant rc=${mrc}"
grep -E '^(PASS|FAIL|QuotaReserved|DONE)' "${L}/h7-k7-mutant-quota72.log"

echo "== restore quota from k4"
kubectl apply -f k4-tas-objects.yaml > /dev/null
echo "quotas now: $(quotas)"
kubectl -n mokka-hetero-kueue get jobs,pods,resourceclaims 2>&1
bash h7-k7-tas-check.sh > /dev/null 2>&1; grc=$?
cp "${L}/h7-k7-tas-check.log" "${L}/h7-k7-green2.log"
echo "k7 after restore rc=${grc}"
grep -E '^(PASS|FAIL|QuotaReserved|DONE)' "${L}/h7-k7-green2.log"
[[ ${mrc} -ne 0 && ${grc} -eq 0 ]] && echo "RESULT mutant RED, restored GREEN" || echo "RESULT unexpected mrc=${mrc} grc=${grc}"
