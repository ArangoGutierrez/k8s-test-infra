#!/bin/bash
# Step 1: clone upstream, check out e8e49aeb, cherry-pick PR #872's commits.
set -euo pipefail
mkdir -p ~/mokka-hetero/logs
cd ~/mokka-hetero
if [ -e src ]; then echo "src already exists, refusing to clobber" >&2; exit 2; fi
git clone https://github.com/NVIDIA/k8s-test-infra src
cd src
git checkout --detach e8e49aeb
git fetch origin pull/872/head:pr872
MB=$(git merge-base e8e49aeb pr872)
echo "merge-base=${MB}"
echo "commits-to-pick=$(git rev-list --count "${MB}..pr872")"
git log --oneline "${MB}..pr872"
git -c user.name=mokka-hetero-h1 -c user.email=h1@localhost cherry-pick "${MB}..pr872"
echo "HEAD=$(git rev-parse HEAD)"
echo "TREE=$(git rev-parse HEAD^{tree})"
git log --oneline -6
ls -d deployments/nvml-mock/helm/nvml-mock/profiles/vr200.yaml deployments/mokka-crds deployments/control-plane
git status --short | head
