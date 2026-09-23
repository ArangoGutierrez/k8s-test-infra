#!/bin/bash
# Step 2: build the two x86 images from the cherry-picked tree. No build args:
# both Dockerfiles default to the public GOPROXY path.
set -uo pipefail
cd ~/mokka-hetero/src
echo "start $(date -u +%FT%TZ) HEAD=$(git rev-parse HEAD)"
docker build -t nvml-mock:hetero -f deployments/nvml-mock/Dockerfile . > ~/mokka-hetero/logs/build-nvml-mock.log 2>&1
rc1=$?
echo "nvml-mock rc=${rc1} $(date -u +%FT%TZ)"
docker build -t mokka-control-plane:hetero -f deployments/control-plane/Dockerfile . > ~/mokka-hetero/logs/build-control-plane.log 2>&1
rc2=$?
echo "control-plane rc=${rc2} $(date -u +%FT%TZ)"
docker image inspect --format '{{.RepoTags}} {{.Id}} {{.Architecture}} {{.Created}}' nvml-mock:hetero mokka-control-plane:hetero
echo "DONE rc1=${rc1} rc2=${rc2}"
