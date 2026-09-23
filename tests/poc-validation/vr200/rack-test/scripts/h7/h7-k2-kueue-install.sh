#!/bin/bash
# H6 Kueue step 2: install Kueue v0.19.5 from the release tgz with
# values-kueue.yaml, then prove from the LIVE objects that it cannot block
# pod creation outside mokka-hetero-kueue and that the DRA mapping is loaded.
# Run from ~/mokka-hetero/h6/kueue (kueue-0.19.5.tgz and values-kueue.yaml
# copied there; tgz sha256 1c97fb124bc18e5b9124e2c84292a0ea9045f2e9e1c0d4648494a4d1311048e0).
set -uo pipefail
cd "$(dirname "$0")" || exit 1
LOG="${HOME}/mokka-hetero/logs/h7-k2-kueue-install.log"
mkdir -p "$(dirname "${LOG}")"
exec > >(tee "${LOG}") 2>&1
echo "start $(date -u +%FT%TZ)"
fail=0

echo "1c97fb124bc18e5b9124e2c84292a0ea9045f2e9e1c0d4648494a4d1311048e0  kueue-0.19.5.tgz" | sha256sum -c -
rc=$?; [[ ${rc} -eq 0 ]] || { echo "FAIL chart tgz hash"; exit 1; }

# Read-only facts the design depends on, recorded before anything changes.
echo "== DeviceClass gpu.nvidia.com extendedResourceName (chart 0.5.0 renders nvidia.com/gpu on resource.k8s.io/v1)"
kubectl get deviceclass gpu.nvidia.com -o jsonpath='{.spec.extendedResourceName}{"\n"}'
echo "== DRAExtendedResource gate as the apiserver reports it (k8s v1.36 default: Beta, on)"
kubectl get --raw /metrics 2>/dev/null | grep -E 'kubernetes_feature_enabled\{name="DRAExtendedResource"' || echo "metric not found"

helm upgrade --install kueue ./kueue-0.19.5.tgz --namespace kueue-system --create-namespace \
  -f values-kueue.yaml --wait --timeout 300s
rc=$?; echo "helm rc=${rc}"; [[ ${rc} -eq 0 ]] || exit 1
kubectl -n kueue-system rollout status deploy/kueue-controller-manager --timeout=180s
rc=$?; echo "rollout rc=${rc}"; [[ ${rc} -eq 0 ]] || exit 1

echo "== live webhooks: every namespaceSelector must be the test namespace, unless the webhook only matches Kueue's own API group"
# H7: the apiserver defaults an unset namespaceSelector to {} (match all), so
# the live objects never carry null the way the helm render does. A webhook
# with a non-test selector passes only if every rule is in kueue.x-k8s.io.
kubectl get mutatingwebhookconfigurations,validatingwebhookconfigurations -o json > /tmp/h7-kueue-webhooks.json
jq -r '.items[] | select(.metadata.name | test("kueue")) | .webhooks[] |
  "\(.name) fp=\(.failurePolicy) ns=\(.namespaceSelector|tostring) groups=\([.rules[].apiGroups[]]|unique|join(","))"' /tmp/h7-kueue-webhooks.json | sort
bad="$(jq -r '
  .items[] | select(.metadata.name | test("kueue")) | .webhooks[] |
  select(.namespaceSelector != {"matchLabels":{"kubernetes.io/metadata.name":"mokka-hetero-kueue"}}) |
  select(any(.rules[].apiGroups[]; . != "kueue.x-k8s.io")) |
  "\(.name) \(.failurePolicy) \(.namespaceSelector|tostring)"' /tmp/h7-kueue-webhooks.json)"
echo "kueue webhooks total: $(jq '[.items[] | select(.metadata.name | test("kueue")) | .webhooks[]] | length' /tmp/h7-kueue-webhooks.json)"
if [[ -n "${bad}" ]]; then echo "FAIL unscoped webhooks:"; echo "${bad}"; fail=1; else echo "PASS all namespaced webhooks scoped to mokka-hetero-kueue"; fi
podfp="$(kubectl get mutatingwebhookconfigurations,validatingwebhookconfigurations -o json | jq -r '
  [.items[] | select(.metadata.name | test("kueue")) | .webhooks[] | select(.name=="mpod.kb.io" or .name=="vpod.kb.io") | .failurePolicy] | unique | join(",")')"
echo "pod webhook failurePolicy: ${podfp}"
[[ "${podfp}" == "Ignore" ]] || { echo "FAIL pod webhooks not Ignore"; fail=1; }

echo "== live manager config"
kubectl -n kueue-system get cm kueue-manager-config -o jsonpath='{.data.controller_manager_config\.yaml}' > /tmp/h7-kueue-cfg.yaml
grep -A3 'deviceClassMappings' /tmp/h7-kueue-cfg.yaml
grep -q 'mokka-hetero.nvidia.com/dra-gpu' /tmp/h7-kueue-cfg.yaml || { echo "FAIL mapping missing"; fail=1; }

echo "== controller log: config errors or DRA mapping errors"
kubectl -n kueue-system logs deploy/kueue-controller-manager --tail=400 | grep -iE 'error|deviceclass' | tail -20

echo "DONE fail=${fail} $(date -u +%FT%TZ)"
exit "${fail}"
