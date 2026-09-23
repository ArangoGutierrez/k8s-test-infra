#!/bin/bash
# Step 8 (part 2): load the vLLM image into one worker per type.
# worker=h100, worker4=gb300, worker7=vr200 (the nodes whose slices were dumped).
set -uo pipefail
NODES=mokka-hetero-worker,mokka-hetero-worker4,mokka-hetero-worker7
IMG=vllm/vllm-openai:v0.30.0
echo "start $(date -u +%FT%TZ)"; df -h / | tail -1
kind load docker-image "${IMG}" --name mokka-hetero --nodes "${NODES}"
rc=$?
echo "kind load docker-image rc=${rc} $(date -u +%FT%TZ)"
if [ "${rc}" -ne 0 ]; then
  echo "fallback: docker save --platform linux/amd64 + kind load image-archive"
  mkdir -p ~/mokka-hetero/tmp
  docker save --platform linux/amd64 -o ~/mokka-hetero/tmp/vllm-v0.30.0-amd64.tar "${IMG}"
  echo "docker save rc=$?"
  kind load image-archive ~/mokka-hetero/tmp/vllm-v0.30.0-amd64.tar --name mokka-hetero --nodes "${NODES}"
  rc=$?
  echo "kind load image-archive rc=${rc} $(date -u +%FT%TZ)"
  rm -f ~/mokka-hetero/tmp/vllm-v0.30.0-amd64.tar
fi
for n in ${NODES//,/ }; do
  echo "== ${n}"
  docker exec "${n}" crictl images --digests | grep vllm
done
df -h / | tail -1
echo "DONE rc=${rc}"
