#!/bin/bash
# H3 step 5: snapshot after the KWOK tier, racks and clones. Exits non-zero if
# the apiserver is not ready, the node count is not 64 (all Ready), a control
# plane or KWOK container restarted, a kind node container restarted since H1
# (then s3b-hide-host-gpu.sh --restart would be due), or /dev/nvidia* leaked
# back into a kind node.
set -uo pipefail
LOG="${HOME}/mokka-hetero/logs/h3-s5-snapshot.log"
exec > >(tee "${LOG}") 2>&1
fail=0
echo "start $(date -u +%FT%TZ)"

echo "== uptime / free -m"
uptime
free -m
echo "== kubectl get --raw /readyz"
r="$(kubectl get --raw /readyz)"; rc=$?; echo "${r} (rc=${rc})"
[[ ${rc} -eq 0 && "${r}" == "ok" ]] || fail=1
kubectl get --raw '/readyz?verbose' | tail -3

echo "== nodes"
total="$(kubectl get nodes --no-headers | wc -l)"
ready="$(kubectl get nodes -o json | jq '[.items[] | select(any(.status.conditions[]; .type=="Ready" and .status=="True"))] | length')"
echo "nodes total=${total} ready=${ready} real=$(kubectl get nodes -l '!type' --no-headers | wc -l) kwok=$(kubectl get nodes -l type=kwok --no-headers | wc -l)"
[[ "${total}" == "64" && "${ready}" == "64" ]] || fail=1

echo "== restarts: control-plane static pods, kwok-controller, kindnet, Mokka control plane"
kubectl -n kube-system get pods -o json | jq -r '.items[] | select(.metadata.name | test("^(kube-apiserver|kube-controller-manager|kube-scheduler|etcd)-|^kwok-controller-")) | "\(.metadata.name) phase=\(.status.phase) restarts=\(.status.containerStatuses[0].restartCount) started=\(.status.containerStatuses[0].state.running.startedAt)"'
cp_restarts="$(kubectl -n kube-system get pods -o json | jq '[.items[] | select(.metadata.name | test("^(kube-apiserver|kube-controller-manager|kube-scheduler|etcd)-|^kwok-controller-")) | .status.containerStatuses[0].restartCount] | add')"
echo "sum of restarts above: ${cp_restarts}"
[[ "${cp_restarts}" == "0" ]] || fail=1
kn="$(kubectl -n kube-system get pods -l app=kindnet -o json | jq '[.items[] | select(.spec.nodeName | startswith("mokka-hetero-")) | .status.containerStatuses[0].restartCount] | "\(length) real kindnet pods, restarts=\(add)"' -r)"
echo "${kn}"
[[ "${kn}" == "10 real kindnet pods, restarts=0" ]] || fail=1
kubectl -n mokka get pods -l app.kubernetes.io/component=control-plane -o wide 2>/dev/null || kubectl -n mokka get pods -o wide | grep control-plane

echo "== kind node containers: restart count and start time (H1 created them at ~10:11Z)"
for n in $(kind get nodes --name mokka-hetero | sort); do
  s="$(docker inspect "${n}" --format '{{.RestartCount}} {{.State.StartedAt}}')"
  d="$(docker exec "${n}" sh -c 'ls -d /dev/nvidia* 2>/dev/null | wc -l')"
  echo "${n} restarts/started=${s} dev-nvidia=${d}"
  case "${s}" in "0 2026-09-23T10:1"*) ;; *) fail=1 ;; esac
  [[ "${d}" == "0" ]] || fail=1
done

echo "== pods"
kubectl get pods -A --no-headers | awk '{print $4}' | sort | uniq -c
echo "not Running/Completed:"
kubectl get pods -A --no-headers | awk '$4!="Running" && $4!="Completed"' | head -20
echo "== docker stats (kind nodes), summed memory"
docker stats --no-stream --format '{{.Name}} {{.CPUPerc}} {{.MemUsage}}' | grep mokka-hetero | sort
docker stats --no-stream --format '{{.Name}} {{.MemUsage}}' | grep mokka-hetero | awk '{v=$2; u=v; gsub(/[0-9.]/,"",u); gsub(/[A-Za-z]/,"",v); if (u=="GiB") v*=1024; s+=v} END {printf "%d MiB across %d containers\n", s, NR}'
echo "== object counts"
echo "resourceslices=$(kubectl get resourceslices --no-headers | wc -l) sgpuracks=$(kubectl get sgpuracks --no-headers | wc -l) leases(kube-node-lease)=$(kubectl -n kube-node-lease get leases --no-headers | wc -l)"
echo "DONE fail=${fail} $(date -u +%FT%TZ)"
exit "${fail}"
