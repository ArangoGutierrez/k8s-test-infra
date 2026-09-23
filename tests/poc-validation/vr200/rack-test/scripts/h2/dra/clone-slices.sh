#!/bin/bash
# Clone one real node's gpu.nvidia.com ResourceSlice onto every KWOK node of
# the same GPU type.
#
# Usage: clone-slices.sh <gpu-type> <source-real-node>
#   gpu-type          vr200 | gb300 | h100
#   source-real-node  a kind worker running nvml-mock with that profile and
#                     the DRA kubelet plugin (e.g. the first nvml-mock/profile=vr200 worker)
#
# Targets are the Nodes labelled mokka-hetero.nvidia.com/tier=kwok and
# mokka-hetero.nvidia.com/gpu-type=<gpu-type> (kwok/gen-nodes.sh). Each target
# must already be bound to a Mokka rack slot (racks/sgpu-inventory.yaml): the
# per-GPU UUIDs come from that SGPURack, so no identity is invented here.
#
# Copied verbatim (identity; dra-driver-nvidia-gpu v0.5.0
# cmd/gpu-kubelet-plugin/deviceinfo.go:168-249): spec.driver, every device
# name (gpu-<minor>, deviceinfo.go:122-124), every attribute except uuid
# (type, productName, brand, architecture, cudaComputeCapability,
# driverVersion, cudaDriverVersion, resource.kubernetes.io/pciBusID and, if
# the source has them, pcieRoot / numaNode / addressingMode), and every
# capacity (memory, partitions.go:34-43).
#
# Rewritten:
#   metadata          fresh object: name <node>-gpu.nvidia.com, ownerReference
#                     to the KWOK Node (as the driver's helper does for its own
#                     node, resourceslice/resourceslicecontroller.go:915-921),
#                     label mokka-hetero.nvidia.com/cloned-from=<source>
#   spec.nodeName     the KWOK node
#   spec.pool.name    the KWOK node (the driver keys its pool by node name,
#                     driver.go:497-501)
#   spec.pool.generation          1 (new pool)
#   spec.pool.resourceSliceCount  1 (the default-gate path publishes one
#                     slice per node, driver.go:488-501)
#   devices[].attributes.uuid     the SGPURack GPU whose pciAddress equals
#                     the device's resource.kubernetes.io/pciBusID
#
# The source node's own plugin never touches these objects: its slice
# informer is filtered to spec.nodeName=<its node>
# (resourceslicecontroller.go:546-554).
set -euo pipefail

GPU_TYPE="${1:?usage: $0 <vr200|gb300|h100> <source-real-node>}"
SRC="${2:?usage: $0 <vr200|gb300|h100> <source-real-node>}"
DRIVER="gpu.nvidia.com"

case "${GPU_TYPE}" in
  vr200 | gb300) WANT_DEVICES=4 ;;
  h100) WANT_DEVICES=8 ;;
  *) echo "unknown gpu type ${GPU_TYPE}" >&2; exit 2 ;;
esac

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

kubectl get resourceslices -o json >"${work}/slices.json"
jq --arg n "${SRC}" --arg d "${DRIVER}" \
  '[.items[] | select(.spec.driver == $d and .spec.nodeName == $n)]' \
  "${work}/slices.json" >"${work}/src.json"

n_src="$(jq 'length' "${work}/src.json")"
if [[ "${n_src}" != "1" ]]; then
  echo "FAIL: ${SRC} has ${n_src} ${DRIVER} slices, want exactly 1" >&2
  exit 1
fi
jq '.[0]' "${work}/src.json" >"${work}/src-slice.json"

# Refuse sources that are not the plain default-gate shape.
jq -e --argjson want "${WANT_DEVICES}" '
  (.spec.pool.resourceSliceCount == 1)
  and ((.spec.sharedCounters // []) | length == 0)
  and (.spec.devices | length == $want)
  and all(.spec.devices[]; ((.taints // []) | length == 0)
                          and (.attributes.uuid.string | type == "string")
                          and (.attributes["resource.kubernetes.io/pciBusID"].string | type == "string"))
' "${work}/src-slice.json" >/dev/null || {
  echo "FAIL: source slice on ${SRC} is not a single untainted ${WANT_DEVICES}-device slice with uuid and pciBusID" >&2
  jq '{pool: .spec.pool, n: (.spec.devices | length)}' "${work}/src-slice.json" >&2
  exit 1
}

kubectl get sgpuracks.mokka.nvidia.com -o json >"${work}/racks.json"

mapfile -t targets < <(kubectl get nodes \
  -l "mokka-hetero.nvidia.com/tier=kwok,mokka-hetero.nvidia.com/gpu-type=${GPU_TYPE}" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
if [[ "${#targets[@]}" -eq 0 ]]; then
  echo "FAIL: no KWOK nodes of type ${GPU_TYPE}" >&2
  exit 1
fi

for t in "${targets[@]}"; do
  uid="$(kubectl get node "${t}" -o jsonpath='{.metadata.uid}')"
  jq --arg t "${t}" --arg g "${GPU_TYPE}" '
    [.items[] | select(.spec.identity.rackGroup == $g) | .spec.nodes[]
     | select(.nodeRef.name == $t) | .gpus]' "${work}/racks.json" >"${work}/slot.json"
  if [[ "$(jq 'length' "${work}/slot.json")" != "1" ]]; then
    echo "FAIL: ${t} is not bound to exactly one ${GPU_TYPE} rack slot" >&2
    exit 1
  fi

  jq --arg t "${t}" --arg uid "${uid}" --arg src "${SRC}" \
     --slurpfile gpus "${work}/slot.json" '
    ($gpus[0][0]) as $rack
    | {
        apiVersion: .apiVersion,
        kind: "ResourceSlice",
        metadata: {
          name: ($t + "-" + .spec.driver),
          labels: {"mokka-hetero.nvidia.com/cloned-from": $src},
          ownerReferences: [{apiVersion: "v1", kind: "Node", name: $t, uid: $uid, controller: true}]
        },
        spec: (.spec
          | .nodeName = $t
          | .pool = {name: $t, generation: 1, resourceSliceCount: 1}
          | .devices |= map(
              .attributes["resource.kubernetes.io/pciBusID"].string as $bdf
              | ([$rack[] | select(.pciAddress == $bdf)]) as $m
              | if ($m | length) != 1
                then error("no unique rack GPU for pciBusID " + $bdf + " on " + $t)
                else .attributes.uuid.string = $m[0].uuid end))
      }' "${work}/src-slice.json" >"${work}/${t}.json"

  kubectl apply -f "${work}/${t}.json"
done

# Post-conditions: every target has one slice with the source identity, and
# every gpu.nvidia.com uuid in the cluster is distinct among cloned slices.
kubectl get resourceslices -l "mokka-hetero.nvidia.com/cloned-from=${SRC}" -o json >"${work}/after.json"
jq -e --slurpfile s "${work}/src-slice.json" --argjson n "${#targets[@]}" '
  def ident: [.spec.devices[] | {name, a: (.attributes | del(.uuid)), c: .capacity}] | sort_by(.name);
  ($s[0] | ident) as $want
  | (.items | length == $n)
    and all(.items[]; ident == $want)
    and ([.items[].spec.devices[].attributes.uuid.string] | (length == (unique | length)))
' "${work}/after.json" >/dev/null || {
  echo "FAIL: cloned slices do not match the source identity or reuse a uuid" >&2
  exit 1
}
echo "OK: ${#targets[@]} ${GPU_TYPE} KWOK slices cloned from ${SRC}"
