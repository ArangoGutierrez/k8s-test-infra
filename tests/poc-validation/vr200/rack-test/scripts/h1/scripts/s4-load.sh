#!/bin/bash
# Step 4: load both locally built images into every node of mokka-hetero.
set -uo pipefail
echo "start $(date -u +%FT%TZ)"
kind load docker-image nvml-mock:hetero mokka-control-plane:hetero --name mokka-hetero
rc=$?
echo "kind load rc=${rc} $(date -u +%FT%TZ)"
for n in $(kind get nodes --name mokka-hetero | sort); do
  echo "== ${n}"
  docker exec "${n}" crictl images | grep -E "nvml-mock|mokka-control-plane"
done
echo "DONE rc=${rc}"
