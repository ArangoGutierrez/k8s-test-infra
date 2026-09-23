#!/bin/bash
# Assertion-level mutation check: each S1/S2/S3 assertion gets one mutant made
# by editing ONE fact in a copy of a green run's dump (the cluster is not
# touched). The unchanged assertion program runs on the mutant and must print
# its target FAIL line. The script prints how many leaf values each mutant
# changed, so a mutant that is too wide shows. Exits non-zero if the baseline
# is not all PASS or any mutant survives.
#   usage: mutate-dumps.sh <run-id>     (dumps in ~/mokka-hetero/out/h5/<run-id>/)
set -uo pipefail
H5="${HOME}/mokka-hetero/h5"
RUNID="${1:?run id}"
SRC="${HOME}/mokka-hetero/out/h5/${RUNID}"
MD="${HOME}/mokka-hetero/out/h5/dump-mutants-${RUNID}"
LOG="${HOME}/mokka-hetero/logs/h5-mutate-dumps-${RUNID}.log"
exec > >(tee "${LOG}") 2>&1
rm -rf "${MD}"; mkdir -p "${MD}"
bad=0
echo "start $(date -u +%FT%TZ) source=${SRC}"

# Helpers prepended to every transform.
DEFS='
def pidx(f): .pods | map(f) | index(true);
def cidx($uid): .claims | map(any(.metadata.ownerReferences[]?; .uid == $uid)) | index(true);
def nidx($n): .nodes | map(.metadata.name == $n) | index(true);
def wantis($w): .metadata.labels["mokka-hetero.nvidia.com/want"] == $w;
def scen($s): .metadata.labels["mokka-hetero.nvidia.com/scenario"] == $s;
def job($j): .metadata.labels["mokka-hetero.nvidia.com/s3-job"] == $j;
def extclaim($pool; $dev): {metadata: {name: "mutant-claim", namespace: "detect-vllm"},
  status: {allocation: {devices: {results: [{driver: "gpu.nvidia.com", pool: $pool, device: $dev, request: "gpu"}]}}}};
'
ARGS_S1=(--argjson n 4)
ARGS_S2=(--argjson fill 84 --argjson rubin 84 --argjson blackwell 84)
ARGS_S3=(--argjson n 18 --argjson realrubin 12)

leaves() { jq -c 'paths(scalars) as $p | [$p, getpath($p)]' "$1"; }

run_prog() { # <scenario> <dump> -> assertion output on stdout
  case "$1" in
    s1) jq -r -L "${H5}" "${ARGS_S1[@]}" -f "${H5}/assert-s1.jq" "$2" ;;
    s2) jq -r -L "${H5}" "${ARGS_S2[@]}" -f "${H5}/assert-s2.jq" "$2" ;;
    s3) jq -r -L "${H5}" "${ARGS_S3[@]}" -f "${H5}/assert-s3.jq" "$2" ;;
  esac
}

for s in s1 s2 s3; do
  out="$(run_prog "${s}" "${SRC}/${s}/dump.json")"; rc=$?
  echo "== baseline ${s}: rc=${rc} PASS=$(grep -c '^PASS ' <<<"${out}") FAIL=$(grep -c '^FAIL ' <<<"${out}")"
  [[ ${rc} -eq 0 && "$(grep -c '^FAIL ' <<<"${out}")" == "0" ]] || bad=$((bad + 1))
  leaves "${SRC}/${s}/dump.json" > "${MD}/${s}.leaves"
done

mut() { # <id> <scenario> <target FAIL prefix> <jq transform>
  local id="$1" s="$2" target="$3" tf="$4" f out rc nf width
  f="${MD}/${id}.json"
  jq "${DEFS} ${tf}" "${SRC}/${s}/dump.json" > "${f}" || { echo "ERROR ${id}: transform failed"; bad=$((bad + 1)); return; }
  width="$(diff "${MD}/${s}.leaves" <(leaves "${f}") | grep -c '^[<>]')"
  out="$(run_prog "${s}" "${f}")"; rc=$?
  nf="$(grep -c '^FAIL ' <<<"${out}")"
  if grep -qF "FAIL ${target}" <<<"${out}"; then
    echo "KILLED ${id} (${s}, ${width} leaf lines changed, ${nf} FAIL): $(grep '^FAIL ' <<<"${out}" | cut -c1-260 | paste -sd'|')"
  else
    echo "SURVIVED ${id} (${s}, ${width} leaf lines changed, rc=${rc}, ${nf} FAIL) target: ${target}"
    bad=$((bad + 1))
  fi
}

# ---- S1
mut m1a s1 "S1 vr200: 4 pods, all bound and Running" \
  'pidx(wantis("vr200")) as $i | .pods[$i].status.phase = "Pending"'
mut m1b s1 "S1 h100: 4 allocated claims, exactly 1 gpu.nvidia.com device each" \
  '.pods[pidx(wantis("h100"))].metadata.uid as $u | cidx($u) as $c | .claims[$c].status.allocation.devices.results[0].driver = "x.example.com"'
mut m1c s1 "S1 vr200: every allocated device is Rubin" \
  '.pods[pidx(wantis("vr200"))].metadata.uid as $u | .claims[cidx($u)].status.allocation.devices.results[0] as $r
   | .slices |= map(if .spec.pool.name == $r.pool then .spec.devices |= map(if .name == $r.device then .attributes.architecture.string = "Blackwell" else . end) else . end)'
mut m1d s1 "S1 vr200: every pod's node is a vr200 node" \
  '.pods[pidx(wantis("vr200"))].spec.nodeName as $n | nidx($n) as $k
   | .nodes[$k].metadata.labels |= (if has("nvml-mock/profile") then .["nvml-mock/profile"] = "gb300" else .["mokka-hetero.nvidia.com/gpu-type"] = "gb300" end)'
mut m1e s1 "S1 gb300: every allocated device is on its pod's node" \
  '[.pods[].spec.nodeName] as $used
   | ([.nodes[] | select(.metadata.labels["mokka-hetero.nvidia.com/gpu-type"] == "gb300") | .metadata.name | select(. as $x | any($used[]; . == $x) | not)] | first) as $free
   | pidx(wantis("gb300")) as $i | .pods[$i].spec.nodeName = $free'
mut m1f s1 "S1: 12 devices allocated in sched-test, none twice" \
  '[.pods | to_entries[] | select(.value | wantis("h100")) | .key] as $h
   | cidx(.pods[$h[0]].metadata.uid) as $cx | cidx(.pods[$h[1]].metadata.uid) as $cy
   | .claims[$cx].status.allocation.devices.results[0].pool = .claims[$cy].status.allocation.devices.results[0].pool
   | .claims[$cx].status.allocation.devices.results[0].device = .claims[$cy].status.allocation.devices.results[0].device
   | .pods[$h[0]].spec.nodeName = .pods[$h[1]].spec.nodeName'

# ---- S2
mut m2a s2 "S2 precondition: the cluster publishes exactly 84 Rubin devices" \
  '(.slices | map(.spec.nodeName == "kwok-vr200-00") | index(true)) as $k | .slices[$k].spec.devices += [.slices[$k].spec.devices[0] | .name = "gpu-99"]'
mut m2b s2 "S2 fill: 84 pods, all bound and Running" \
  'pidx(scen("s2-fill")) as $i | .pods[$i].status.phase = "Pending"'
mut m2c s2 "S2 fill: 84 allocated claims, 1 device each, together exactly" \
  '[.pods | to_entries[] | select(.value | scen("s2-fill")) | .key] as $f
   | cidx(.pods[$f[0]].metadata.uid) as $cx | cidx(.pods[$f[1]].metadata.uid) as $cy
   | .claims[$cx].status.allocation.devices.results[0] = .claims[$cy].status.allocation.devices.results[0]'
mut m2d s2 "S2 extra: exactly one extra pod, Pending and unbound" \
  'pidx(scen("s2-extra")) as $i | .pods[$i].spec.nodeName = "kwok-gb300-00" | .pods[$i].status.phase = "Running"'
mut m2e s2 "S2 extra: its claim exists and has no allocation" \
  'cidx(.pods[pidx(scen("s2-extra"))].metadata.uid) as $c
   | .claims[$c].status.allocation = {devices: {results: [{driver: "gpu.nvidia.com", pool: "kwok-vr200-00", device: "gpu-0", request: "gpu"}]}}'
mut m2f s2 "S2 extra: the scheduler recorded FailedScheduling for this pod (uid)" \
  '.events |= map(if .reason == "FailedScheduling" then .involvedObject.uid = "00000000-0000-0000-0000-stale0000000" else . end)'
mut m2g s2 "S2: zero non-Rubin (so zero Blackwell) devices allocated to any sched-test claim" \
  'cidx(.pods[pidx(scen("s2-extra"))].metadata.uid) as $c
   | .claims[$c].status.allocation = {devices: {results: [{driver: "gpu.nvidia.com", pool: "kwok-h100-00", device: "gpu-0", request: "gpu"}]}}'
mut m2h s2 "S2: all 84 Blackwell devices stayed free cluster-wide" \
  '.claims += [extclaim("kwok-gb300-00"; "gpu-0")]'

# ---- S3
mut m3a s3 "S3 A: 18 pods, all bound and Running" \
  'pidx(job("a")) as $i | .pods[$i].status.phase = "Pending"'
mut m3b s3 "S3 A: 18 distinct nodes" \
  '[.pods | to_entries[] | select(.value | job("a")) | .key] as $a
   | .pods[$a[1]].spec.nodeName as $to | cidx(.pods[$a[0]].metadata.uid) as $c
   | .pods[$a[0]].spec.nodeName = $to
   | .claims[$c].status.allocation.devices.results |= map(.pool = $to)'
mut m3c s3 "S3 A: every A node carries nvidia.com/gpu.clique and all share ONE value" \
  '([.nodes[] | select(.metadata.labels["mokka-hetero.nvidia.com/gpu-type"] == "gb300") | .metadata.labels["nvidia.com/gpu.clique"]] | first) as $gb
   | nidx(.pods[pidx(job("a"))].spec.nodeName) as $k | .nodes[$k].metadata.labels["nvidia.com/gpu.clique"] = $gb'
mut m3d s3 "S3 A: that value is the vr200 SGPURack's fabricUUID.cliqueID" \
  '.racks |= map(if .spec.identity.rackGroup == "vr200" then .spec.identity.fabricUUID = "00000000-0000-0000-0000-000000000000" else . end)'
mut m3e s3 "S3 A: no A pod on a real (non-KWOK) node" \
  'nidx(.pods[pidx(job("a"))].spec.nodeName) as $k | .nodes[$k].metadata.labels |= del(.type)'
mut m3f s3 "S3 A: every claim holds 4 Rubin devices, all on its pod's node" \
  'cidx(.pods[pidx(job("a"))].metadata.uid) as $c | .claims[$c].status.allocation.devices.results |= .[0:3]'
mut m3g s3 "S3 B: 18 pods, none bound, all Pending" \
  'pidx(job("b")) as $i | .pods[$i].spec.nodeName = "kwok-vr200-00"'
mut m3h s3 "S3 B: no B claim allocated" \
  'cidx(.pods[pidx(job("b"))].metadata.uid) as $c
   | .claims[$c].status.allocation = {devices: {results: [{driver: "gpu.nvidia.com", pool: "kwok-vr200-00", device: "gpu-0", request: "gpus"}]}}'
mut m3i s3 "S3 B: the scheduler recorded FailedScheduling for B pods (uid)" \
  '.events |= map(if .reason == "FailedScheduling" then .involvedObject.uid = "00000000-0000-0000-0000-stale0000000" else . end)'
mut m3j s3 "S3 B: the 12 real VR200 devices (no clique) stayed free" \
  '.claims += [extclaim("mokka-hetero-worker7"; "gpu-0")]'

echo "DONE bad=${bad} $(date -u +%FT%TZ)"
exit "${bad}"
