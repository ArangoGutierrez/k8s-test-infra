#!/bin/bash
# Resolve the Kueue v0.19.5 index by the promoter-pinned digest in candidate
# registries, anonymously, and print the raw-bytes sha256 and platform children.
set -uo pipefail
cd "$(dirname "$0")"
P=sha256:a55949705d7ab1fe38034da56c5af95deecec3da0abebb209a372f7a5c414a2d
A='application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json'
for repo in gcr.io/k8s-staging-kueue/kueue us-central1-docker.pkg.dev/k8s-staging-images/kueue/kueue registry.k8s.io/kueue/kueue; do
  host="${repo%%/*}"; rpath="${repo#*/}"; out="idx-${host}.json"
  tok="$(curl -sS --max-time 20 "https://${host}/v2/token?scope=repository:${rpath}:pull&service=${host}" 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin).get("token",""))' 2>/dev/null)"
  code="$(curl -sSL --max-time 30 -o "${out}" -w '%{http_code}' ${tok:+-H "Authorization: Bearer ${tok}"} -H "Accept: ${A}" "https://${host}/v2/${rpath}/manifests/${P}")"
  echo "== ${repo}@${P}: http=${code} bytes=$(wc -c < "${out}")"
  if [[ "${code}" == "200" ]]; then
    echo "sha256 of raw index bytes: sha256:$(shasum -a 256 "${out}" | cut -d' ' -f1)"
    python3 -c "import json;d=json.load(open('${out}'));[print('  ',m['platform'].get('os'),m['platform'].get('architecture'),m['digest']) for m in d.get('manifests',[])]"
  else
    head -c 300 "${out}"; echo
  fi
done
