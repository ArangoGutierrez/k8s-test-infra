#!/bin/bash
# Step 8 (part 1): pull the wave-2 engine image once into the VM's Docker.
set -uo pipefail
echo "start $(date -u +%FT%TZ)"
docker pull --platform linux/amd64 vllm/vllm-openai:v0.30.0
rc=$?
echo "pull rc=${rc} $(date -u +%FT%TZ)"
docker image inspect --format '{{.RepoTags}} {{.Id}} {{.Architecture}} {{.RepoDigests}} {{.Size}}' vllm/vllm-openai:v0.30.0
echo "DONE rc=${rc}"
