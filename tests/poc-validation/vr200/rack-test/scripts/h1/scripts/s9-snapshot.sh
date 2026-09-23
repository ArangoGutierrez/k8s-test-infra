#!/bin/bash
# Step 9: resource snapshot of the VM with the real tier running.
set -uo pipefail
date -u +%FT%TZ
echo "== nproc / load"; nproc; uptime
echo "== free -m"; free -m
echo "== df -h /"; df -h / | tail -1
echo "== docker stats --no-stream"
docker stats --no-stream --format '{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}'
echo "== summed kind node memory (MiB)"
docker stats --no-stream --format '{{.MemUsage}}' | awk '{v=$1; u=v; gsub(/[0-9.]/,"",u); gsub(/[A-Za-z]/,"",v); if (u=="GiB") v*=1024; else if (u=="KiB"||u=="kB") v/=1024; s+=v} END {printf "%.0f MiB across %d containers\n", s, NR}'
echo "== docker system df"; docker system df
echo "== pods not Running/Completed"
kubectl --context kind-mokka-hetero get pods -A --no-headers | awk '$4!="Running" && $4!="Completed"' | head
echo "== pod count"; kubectl --context kind-mokka-hetero get pods -A --no-headers | wc -l
