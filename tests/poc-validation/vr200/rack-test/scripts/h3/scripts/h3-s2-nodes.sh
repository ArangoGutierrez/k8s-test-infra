#!/bin/bash
# H3 step 2: create the 54 KWOK Nodes, one canary first, and verify:
#  - generated nodes: 54, 18 per type, no nvml-mock/profile label, unique
#    InternalIPs in 172.18.250.0/24 that are never a real node's IP;
#  - server-side dry-run keeps status.addresses (else KWOK would fall back to
#    the controller pod IP and kindnetd on the real nodes would panic);
#  - canary: Ready, keeps its InternalIP, every real node got a valid route
#    to its podCIDR, kindnet restarts unchanged, no reconcile failure;
#  - all 54 Ready, 18 per type, no nvml-mock label, 54 fake routes on every
#    real node, kindnet restarts unchanged, and no nvml-mock / DRA / Mokka pod
#    on any fake node.
# Exits non-zero on any failure. Rolls back (deletes the canary) if the
# canary fails.
set -uo pipefail
H2="${HOME}/mokka-hetero/h2"
H3="${HOME}/mokka-hetero/h3"
LOG="${HOME}/mokka-hetero/logs/h3-s2-nodes.log"
exec > >(tee "${LOG}") 2>&1

CANARY="kwok-vr200-00"
fail=0
echo "start $(date -u +%FT%TZ)"

real_nodes() { kind get nodes --name mokka-hetero | sort; }
kindnet_restarts() {
  kubectl -n kube-system get pods -l app=kindnet -o json |
    jq -r '.items[] | select(.spec.nodeName | startswith("mokka-hetero-")) | "\(.spec.nodeName) \(.status.containerStatuses[0].restartCount)"' | sort
}
kindnet_failures_since() {  # $1 = RFC3339 time
  local n=0 c
  for p in $(kubectl -n kube-system get pods -l app=kindnet -o json | jq -r '.items[] | select(.spec.nodeName | startswith("mokka-hetero-")) | .metadata.name'); do
    c="$(kubectl -n kube-system logs "${p}" --since-time="$1" 2>/dev/null | grep -c -E 'Failed to reconcile|panic|invalid gateway')"
    n=$((n + c))
  done
  echo "${n}"
}

# ---------------------------------------------------------------- generate
bash "${H3}/gen-nodes-h3.sh" >"${H3}/nodes-h3.yaml" || { echo "FAIL generate"; exit 1; }
removed="$(diff "${H2}/kwok/nodes.yaml" "${H3}/nodes-h3.yaml" | grep -c '^<')"
added="$(diff "${H2}/kwok/nodes.yaml" "${H3}/nodes-h3.yaml" | grep -c '^>')"
echo "== diff vs H2 nodes.yaml: removed=${removed} added=${added} (want 0 and 270 = 5 x 54)"
diff "${H2}/kwok/nodes.yaml" "${H3}/nodes-h3.yaml" | grep '^>' | sed -E 's/[0-9]+$/N/; s/kwok-(vr200|gb300|h100)-N/kwok-<t>-N/' | sort | uniq -c
[[ "${removed}" == "0" && "${added}" == "270" ]] || { echo "FAIL generator diff"; fail=1; }

kubectl create --dry-run=client -f "${H3}/nodes-h3.yaml" -o json |
  jq -s '[.[] | if .kind == "List" then .items[] else . end]' >"${H3}/nodes-h3.json"
jq '{apiVersion: "v1", kind: "List", items: .}' "${H3}/nodes-h3.json" >"${H3}/nodes-h3-list.json"
echo "== generated"
jq -r 'length as $n | "nodes=\($n)"' "${H3}/nodes-h3.json"
jq -r 'group_by(.metadata.labels["mokka-hetero.nvidia.com/gpu-type"]) | map("\(.[0].metadata.labels["mokka-hetero.nvidia.com/gpu-type"])=\(length)") | join(" ")' "${H3}/nodes-h3.json"
jq -e 'length == 54
  and ([.[] | select(.metadata.labels | has("nvml-mock/profile"))] | length == 0)
  and (group_by(.metadata.labels["mokka-hetero.nvidia.com/gpu-type"]) | map(length) == [18,18,18])
  and ([.[] | .status.addresses[] | select(.type == "InternalIP") | .address] | (length == 54) and (unique | length == 54) and all(test("^172\\.18\\.250\\.[0-9]+$")))' \
  "${H3}/nodes-h3.json" >/dev/null && echo "PASS generated: 54, 18/18/18, no nvml-mock/profile, 54 unique 172.18.250.x" || { echo "FAIL generated nodes"; fail=1; }
real_ips="$(kubectl get nodes -o json | jq -r '.items[].status.addresses[] | select(.type=="InternalIP") | .address' | sort)"
fake_ips="$(jq -r '.[] | .status.addresses[] | select(.type=="InternalIP") | .address' "${H3}/nodes-h3.json" | sort)"
clash="$(comm -12 <(echo "${real_ips}") <(echo "${fake_ips}"))"
echo "real InternalIPs: $(echo ${real_ips})"
[[ -z "${clash}" ]] && echo "PASS no fake IP equals an existing node IP" || { echo "FAIL IP clash: ${clash}"; fail=1; }
[[ ${fail} -eq 0 ]] || { echo "DONE fail=${fail} (pre-create)"; exit 1; }

# ------------------------------------------------ server-side dry run keeps status
jq --arg c "${CANARY}" '.[] | select(.metadata.name == $c)' "${H3}/nodes-h3.json" >"${H3}/canary.json"
dry="$(kubectl create --dry-run=server -f "${H3}/canary.json" -o json | jq -c '{addresses: .status.addresses, cpu: .status.capacity.cpu}')"
echo "server dry-run kept: ${dry}"
[[ "${dry}" == '{"addresses":[{"address":"172.18.250.1","type":"InternalIP"},{"address":"kwok-vr200-00","type":"Hostname"}],"cpu":"64"}' ]] ||
  { echo "FAIL apiserver does not keep status.addresses on create; not creating anything"; exit 1; }

# ---------------------------------------------------------------- canary
echo "== kindnet restarts before"
before="$(kindnet_restarts)"; echo "${before}"
[[ "$(echo "${before}" | grep -c '^mokka-hetero-')" == "10" ]] || { echo "FAIL expected 10 real kindnet pods (selector app=kindnet)"; exit 1; }
t0="$(date -u +%FT%TZ)"
kubectl create -f "${H3}/canary.json"
kubectl wait --for=condition=Ready "node/${CANARY}" --timeout=120s; rc=$?; echo "canary wait rc=${rc}"
echo "waiting 35s for at least three kindnet reconcile ticks (10s ticker)"
sleep 35
kubectl get node "${CANARY}" -o wide
caddr="$(kubectl get node "${CANARY}" -o json | jq -c '[.status.addresses[] | {type, address}]')"
ccidr="$(kubectl get node "${CANARY}" -o jsonpath='{.spec.podCIDR}')"
echo "canary addresses=${caddr} podCIDR=${ccidr}"
cfail=0
[[ ${rc} -eq 0 ]] || cfail=1
[[ "${caddr}" == '[{"type":"InternalIP","address":"172.18.250.1"},{"type":"Hostname","address":"kwok-vr200-00"}]' ]] || { echo "FAIL canary InternalIP changed"; cfail=1; }
[[ -n "${ccidr}" ]] || { echo "FAIL canary has no podCIDR"; cfail=1; }
for n in $(real_nodes); do
  r="$(docker exec "${n}" ip -4 route show "${ccidr}")"
  echo "${n}: ${r:-NO ROUTE}"
  [[ "${r}" == "${ccidr} via 172.18.250.1 dev eth0 " || "${r}" == "${ccidr} via 172.18.250.1 dev eth0" ]] || cfail=1
done
after="$(kindnet_restarts)"
[[ "${before}" == "${after}" ]] && echo "PASS kindnet restarts unchanged" || { echo "FAIL kindnet restarts changed:"; echo "${after}"; cfail=1; }
nf="$(kindnet_failures_since "${t0}")"; echo "kindnet failure lines since ${t0}: ${nf}"
[[ "${nf}" == "0" ]] || cfail=1
if [[ ${cfail} -ne 0 ]]; then
  echo "FAIL canary; rolling back"
  kubectl delete node "${CANARY}"
  echo "DONE fail=1 (canary) $(date -u +%FT%TZ)"; exit 1
fi
echo "PASS canary"

# ---------------------------------------------------------------- all 54
kubectl create -f "${H3}/nodes-h3-list.json" 2>&1 | grep -v "AlreadyExists" | sed -E 's/^node\/(kwok-[a-z0-9]+)-[0-9]+ created$/node\/\1-NN created/' | sort | uniq -c
kubectl wait --for=condition=Ready node -l type=kwok --timeout=300s >/dev/null; rc=$?; echo "wait all rc=${rc}"
[[ ${rc} -eq 0 ]] || fail=1
echo "waiting 35s for kindnet reconcile ticks"
sleep 35

echo "== fake nodes"
kubectl get nodes -l type=kwok -L mokka-hetero.nvidia.com/gpu-type -L nvml-mock/profile --no-headers | awk '{print $2, $6, ($7==""?"-":$7)}' | sort | uniq -c
ready="$(kubectl get nodes -l type=kwok -o json | jq '[.items[] | select(any(.status.conditions[]; .type=="Ready" and .status=="True"))] | length')"
echo "fake nodes Ready: ${ready}"
[[ "${ready}" == "54" ]] || { echo "FAIL fake Ready != 54"; fail=1; }
for t in vr200 gb300 h100; do
  c="$(kubectl get nodes -l "type=kwok,mokka-hetero.nvidia.com/gpu-type=${t}" --no-headers | wc -l)"
  echo "type ${t}: ${c}"; [[ "${c}" == "18" ]] || fail=1
done
nm="$(kubectl get nodes -l 'type=kwok,nvml-mock/profile' --no-headers 2>/dev/null | wc -l)"
echo "fake nodes carrying nvml-mock/profile: ${nm}"
[[ "${nm}" == "0" ]] || { echo "FAIL F2"; fail=1; }
ipchk="$(kubectl get nodes -l type=kwok -o json | jq '[.items[].status.addresses[] | select(.type=="InternalIP") | .address] | (length == 54) and (unique | length == 54) and all(test("^172\\.18\\.250\\."))')"
echo "fake InternalIPs kept (54 unique 172.18.250.x): ${ipchk}"
[[ "${ipchk}" == "true" ]] || fail=1

echo "== fake-node routes on each real node (want 54, all via 172.18.250.x)"
for n in $(real_nodes); do
  c="$(docker exec "${n}" ip -4 route | grep -c ' via 172\.18\.250\.')"
  echo "${n}: ${c}"; [[ "${c}" == "54" ]] || fail=1
done
after="$(kindnet_restarts)"
knfail=0
[[ "${before}" == "${after}" ]] && echo "PASS kindnet restarts unchanged" || { echo "FAIL kindnet restarts changed:"; echo "${after}"; knfail=1; }
nf="$(kindnet_failures_since "${t0}")"; echo "kindnet failure lines since ${t0}: ${nf}"
[[ "${nf}" == "0" ]] || knfail=1
if [[ ${knfail} -ne 0 ]]; then
  echo "FAIL kindnet disturbed by the fake nodes; rolling back all of them to protect the real tier"
  kubectl delete nodes -l type=kwok
  echo "DONE fail=1 (kindnet) $(date -u +%FT%TZ)"; exit 1
fi

echo "== pods on fake nodes (namespace owner-kind/owner phase)"
kubectl get pods -A -o json | jq -r '.items[] | select(.spec.nodeName // "" | startswith("kwok-")) | "\(.metadata.namespace) \(.metadata.ownerReferences[0].kind)/\(.metadata.ownerReferences[0].name) \(.status.phase)"' | sort | uniq -c
bad="$(kubectl get pods -A -o json | jq -r '.items[] | select(.spec.nodeName // "" | startswith("kwok-")) | select(.metadata.namespace == "mokka" or .metadata.namespace == "nvidia" or (.metadata.name | test("nvml-mock|dra-driver|control-plane"))) | "\(.metadata.namespace)/\(.metadata.name) on \(.spec.nodeName)"')"
echo "nvml-mock / DRA / Mokka pods on fake nodes: ${bad:-none}"
[[ -z "${bad}" ]] || { echo "FAIL forbidden pod on a fake node"; fail=1; }
echo "== kubectl get pods -A -o wide, rows on kwok-* nodes, by namespace and name prefix"
kubectl get pods -A -o wide --no-headers | awk '{for(i=1;i<=NF;i++) if ($i ~ /^kwok-(vr200|gb300|h100)-[0-9]+$/) {p=$2; sub(/-[a-z0-9]+$/, "-*", p); print $1, p, $4}}' | sort | uniq -c
echo "== real-tier DaemonSets (desired/ready unchanged)"
kubectl get ds -A --no-headers | awk '{print $1, $2, "desired="$3, "ready="$5}'

echo "DONE fail=${fail} $(date -u +%FT%TZ)"
exit "${fail}"
