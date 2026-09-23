#!/usr/bin/env python3
"""H4 gate: what the vLLM pod saw (phase B) must equal the ResourceSlice entry
of the device DRA allocated to it, and the brief's fixed values; the run must
show no L4 activity. Exits 1 on any mismatch.

Usage: h4-check.py <out-dir> <slices.json>
  <out-dir> holds h100/, gb300/, vr200/ run directories (pod.log, claims.yaml,
  watchdog.log, dmesg-nvrm.txt) as written by h4-run.sh.
"""
import json
import re
import sys

import yaml

# Brief step 5 (H100 9.0 / 80Gi, GB300 10.0 / 288Gi, VR200 10.7 / 288Gi) plus
# names from H1's slice table and go-nvml v0.13.3-1 const.go:118-122
# (DEVICE_ARCH_HOPPER 9, BLACKWELL 10, RUBIN 13).
FIXED = {
    "h100": {"name": "NVIDIA H100 80GB HBM3", "cc": "9.0", "mem": 80 << 30, "arch": 9},
    "gb300": {"name": "NVIDIA GB300 NVL", "cc": "10.0", "mem": 288 << 30, "arch": 10},
    "vr200": {"name": "NVIDIA Graphics Device", "cc": "10.7", "mem": 288 << 30, "arch": 13},
}
GI = {"Gi": 1 << 30}

out_dir, slices_path = sys.argv[1], sys.argv[2]
slices = json.load(open(slices_path))
fails = 0


def check(label, got, want):
    global fails
    ok = got == want
    fails += not ok
    print("%s %-40s got=%r want=%r" % ("PASS" if ok else "FAIL", label, got, want))


def phase_b(log):
    return log.split("PHASE B:", 1)[1] if "PHASE B:" in log else ""


for t, fx in FIXED.items():
    d = "%s/%s" % (out_dir, t)
    print("== %s" % t)
    log = open(d + "/pod.log").read()
    b = phase_b(log)
    res = dict(re.findall(r"^RESULT (\w+)=(.*)$", b, re.M))
    line = re.search(r"^IDENTITY gpu0 (.*)$", b, re.M)
    line = line.group(1) if line else ""
    ident = {k: m.group(1) for k in ("arch", "uuid", "pci")
             for m in [re.search(r"\b%s=(\S+)" % k, line)] if m}
    ident_name = re.search(r"^name=(.*?) arch=", line)
    smi = re.search(r"^GPU 0: (.*?) \(UUID", b, re.M)

    claims = yaml.safe_load(open(d + "/claims.yaml"))
    alloc = claims["items"][0]["status"]["allocation"]["devices"]["results"][0]
    dev = [x for x in slices[t]["items"][0]["spec"]["devices"] if x["name"] == alloc["device"]][0]
    attr = {k: list(v.values())[0] for k, v in dev["attributes"].items()}
    mem_q = dev["capacity"]["memory"]["value"]
    slice_mem = int(mem_q[:-2]) * GI[mem_q[-2:]]
    slice_cc = ".".join(attr["cudaComputeCapability"].split(".")[:2])
    slice_pci = attr["resource.kubernetes.io/pciBusID"].lower()
    print("   allocated %s/%s on %s" % (alloc["pool"], alloc["device"], alloc["driver"]))

    # brief's fixed values
    check("vllm device_name_0 == fixed", res.get("device_name_0"), fx["name"])
    check("vllm compute_capability_0 == fixed", res.get("compute_capability_0"), fx["cc"])
    check("vllm total_memory_bytes_0 == fixed", int(res.get("total_memory_bytes_0", -1)), fx["mem"])
    check("nvml arch enum == fixed", int(ident.get("arch", -1)), fx["arch"])
    check("vllm platform", res.get("platform"), "NvmlCudaPlatform")
    # the allocated device's ResourceSlice entry
    check("slice productName == vllm name", attr["productName"], res.get("device_name_0"))
    check("slice productName == nvidia-smi -L", attr["productName"], smi.group(1) if smi else None)
    check("slice productName == nvml name", attr["productName"],
          ident_name.group(1) if ident_name else None)
    check("slice cc == vllm cc", slice_cc, res.get("compute_capability_0"))
    check("slice memory == vllm bytes", slice_mem, int(res.get("total_memory_bytes_0", -1)))
    check("slice uuid == nvml uuid", attr["uuid"], ident.get("uuid"))
    pci = (ident.get("pci") or "").lower()
    check("slice pciBusID == nvml busId", slice_pci, pci[4:] if len(pci) == 16 else pci)
    # no CUDA context anywhere, no L4 activity
    check("cuda_context_created", res.get("cuda_context_created"), "False")
    check("serve_listening", res.get("serve_listening"), "0")
    wd = open(d + "/watchdog.log").read()
    check("watchdog saw no L4 process", "L4 PROCESS" in wd, False)
    check("watchdog ended alert=no", bool(re.search(r"^stop .* alert=no$", wd, re.M)), True)
    check("no new NVRM kernel lines", open(d + "/dmesg-nvrm.txt").read().strip(), "")

print("CHECK fails=%d" % fails)
sys.exit(1 if fails else 0)
