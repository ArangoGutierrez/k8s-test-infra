#!/bin/bash
# Namespace detect-vllm, the three x1 claim templates, and the probes ConfigMap.
# Idempotent.
set -uo pipefail
CTX=kind-mokka-hetero
H4=~/mokka-hetero/h4
kubectl --context "${CTX}" apply -f "${H4}/manifests/base.yaml"
echo "apply rc=$?"
kubectl --context "${CTX}" -n detect-vllm create configmap h4-probes \
  --from-file="${H4}/probes/" --dry-run=client -o yaml \
  | kubectl --context "${CTX}" apply -f -
echo "configmap rc=$?"
kubectl --context "${CTX}" -n detect-vllm get resourceclaimtemplates,configmaps
kubectl --context "${CTX}" -n detect-vllm get configmap h4-probes -o jsonpath='{.data}' | python3 -c 'import json,sys; print(sorted(json.load(sys.stdin)))'
