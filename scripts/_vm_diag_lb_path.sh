#!/usr/bin/env bash
# One-shot LB-path live diagnostic for the IK2221 VM.
# Run on the VM (or via scripts/vm-run.sh), as root (or with sudo).
#
# Steps:
#   1. Tear down any leftover POX/Click/Mininet
#   2. Start POX (baseController) in the background
#   3. Build the full MyTopo with the same Mininet flags as topology_test.py
#   4. Wait briefly for Click/OVS to settle
#   5. Snapshot: click pids, click stderr/report files, ovs-ofctl dump-flows
#   6. Run a single ping h1 -> VIP and a single curl POST h1 -> VIP, with
#      tcpdump on each NFV interface during the probes
#   7. Snapshot again, dump everything to /tmp/diag-lb-path/
#
# Output dir is fully self-contained so it can be scp'd back to the host.

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

OUT=/tmp/diag-lb-path
rm -rf "$OUT" && mkdir -p "$OUT"
exec > >(tee "$OUT/diag.log") 2>&1

echo "[diag] root=$ROOT  out=$OUT"
echo "[diag] cleaning leftover state"
pkill -9 -f 'pox.py baseController' 2>/dev/null || true
killall -9 click 2>/dev/null || true
mn -c >/dev/null 2>&1 || true
sleep 1
# Truncate stale stderr files so we only see THIS run's errors
: >/tmp/lb1.stderr; : >/tmp/napt.stderr; : >/tmp/ids.stderr

echo "[diag] copying controller + click sources to /opt/pox/ext/"
cp applications/controller/* /opt/pox/ext/
cp applications/nfv/*.click /opt/pox/ext/

export IK2221_NAPT_REPORT="$OUT/napt.report"
export IK2221_IDS_REPORT="$OUT/ids.report"
export IK2221_LB_REPORT="$OUT/lb1.report"
export IK2221_NAPT_STDERR="$OUT/napt.stderr"
export IK2221_IDS_STDERR="$OUT/ids.stderr"
export IK2221_LB_STDERR="$OUT/lb1.stderr"

echo "[diag] starting POX -> $OUT/pox.stdout"
# Tell click_wrapper to put the report in our diag dir.
export IK2221_NAPT_REPORT="$OUT/napt.report"
export IK2221_IDS_REPORT="$OUT/ids.report"
export IK2221_LB_REPORT="$OUT/lb1.report"
python /opt/pox/pox.py baseController >"$OUT/pox.stdout" 2>&1 &
POX_PID=$!
echo "[diag] POX pid=$POX_PID"
sleep 3

echo "[diag] driving Mininet with MyTopo (autoSetMacs=True autoStaticArp=False)"
python3 - <<'PYEOF' > "$OUT/mininet.log" 2>&1 || echo "[diag] mininet python script exited with $?"
import os, sys, time, subprocess
sys.path.insert(0, "/home/ik2221/ML-networking")
sys.path.insert(0, "/home/ik2221/ML-networking/topology")
from mininet.net import Mininet
from mininet.node import RemoteController, OVSSwitch
from topology import MyTopo, startup_services
OUT = "/tmp/diag-lb-path"

def dump(label, cmd):
    print(f"\n=== {label}: {cmd} ===", flush=True)
    rc = subprocess.run(["bash","-lc",cmd], capture_output=True, text=True)
    sys.stdout.write(rc.stdout)
    if rc.stderr:
        sys.stdout.write("STDERR:\n"+rc.stderr)
    sys.stdout.flush()

topo = MyTopo()
ctrl = RemoteController("c0", ip="127.0.0.1", port=6633)
net = Mininet(topo=topo, switch=OVSSwitch, controller=ctrl,
              autoSetMacs=True, autoStaticArp=False, build=True, cleanup=True)
net.start()
startup_services(net)
print("[diag] startup_services done; sleeping 8s for Click+OVS warmup", flush=True)
time.sleep(8)

dump("click processes", "pgrep -af click")
dump("click stderr sizes", f"ls -la {OUT}/*.stderr {OUT}/*.report")
dump("ip neigh on h1 (pre)", "ip netns identify $$; ")  # will be empty in script context
h1 = net.get('h1')
llm1 = net.get('llm1')

print("\n=== ip neigh on h1 (pre, via h1.cmd) ===", flush=True)
print(h1.cmd('ip -4 neigh ; ip route'))
print("\n=== ip neigh on llm1 (pre) ===", flush=True)
print(llm1.cmd('ip -4 neigh ; ip route'))

dump("ovs-ofctl dump-flows sw1",  "ovs-ofctl dump-flows sw1")
dump("ovs-ofctl dump-flows sw2",  "ovs-ofctl dump-flows sw2")
dump("ovs-ofctl dump-flows sw3",  "ovs-ofctl dump-flows sw3")
dump("ovs-ofctl dump-flows napt", "ovs-ofctl dump-flows napt")
dump("ovs-ofctl dump-flows ids",  "ovs-ofctl dump-flows ids")
dump("ovs-ofctl dump-flows lb1",  "ovs-ofctl dump-flows lb1")

# Start tcpdumps on each NFV interface (short rolling capture)
def start_pcap(iface, fname):
    return subprocess.Popen(["tcpdump","-i",iface,"-U","-w",fname,
                             "-s","256","not stp"],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

pcaps = []
for iface,fname in [
    ("napt-eth1",f"{OUT}/napt-eth1.pcap"),
    ("napt-eth2",f"{OUT}/napt-eth2.pcap"),
    ("ids-eth1", f"{OUT}/ids-eth1.pcap"),
    ("ids-eth3", f"{OUT}/ids-eth3.pcap"),
    ("lb1-eth1", f"{OUT}/lb1-eth1.pcap"),
    ("lb1-eth2", f"{OUT}/lb1-eth2.pcap"),
]:
    try:
        pcaps.append(start_pcap(iface, fname))
    except Exception as e:
        print(f"[diag] failed pcap on {iface}: {e}", flush=True)
time.sleep(1)

print("\n=== probe 1: h1 ping -c 3 100.0.0.45 ===", flush=True)
print(h1.cmd("ping -W 2 -c 3 100.0.0.45"))
print("\n=== ip neigh on h1 (post-ping) ===", flush=True)
print(h1.cmd('ip -4 neigh'))

dump("probe 2: pgrep click", "pgrep -af click")

print("\n=== probe 3: h1 curl POST -> VIP (verbose) ===", flush=True)
print(h1.cmd("curl --connect-timeout 4 --max-time 6 -v -X POST http://100.0.0.45/ -d 'hello' 2>&1 | head -30"))

print("\n=== probe 4: h1 curl GET -> VIP (verbose) ===", flush=True)
print(h1.cmd("curl --connect-timeout 4 --max-time 6 -v http://100.0.0.45/ 2>&1 | head -30"))

print("\n=== probe 5: h1 -> 100.0.0.40 direct (skip LB) ===", flush=True)
print(h1.cmd("curl --connect-timeout 4 --max-time 6 -v http://100.0.0.40/ 2>&1 | head -30"))

print("\n=== llm1 saw any TCP? (server logs) ===", flush=True)
print(llm1.cmd("ss -tnl"))

print("\n=== ip neigh after probes ===", flush=True)
print(h1.cmd('ip -4 neigh'))

# Stop pcaps
for p in pcaps:
    p.terminate()
for p in pcaps:
    try: p.wait(2)
    except Exception: p.kill()

dump("ovs-ofctl dump-flows lb1 (post)",  "ovs-ofctl dump-flows lb1")
dump("ovs-ofctl dump-flows napt (post)", "ovs-ofctl dump-flows napt")
dump("ovs-ofctl dump-flows ids  (post)", "ovs-ofctl dump-flows ids")

# Send SIGINT to click so DriverManager unpauses and prints counters.
print("\n=== SIGINT click so DriverManager flushes counters ===", flush=True)
shell_cmd = ("for p in $(pgrep -x click); do echo killing $p; kill -INT $p; done; "
             "sleep 2; "
             "echo '--- NAPT REPORT ---'; cat /tmp/diag-lb-path/napt.report; "
             "echo '--- LB1  REPORT ---'; cat /tmp/diag-lb-path/lb1.report")
dump("click reports (after SIGINT)", shell_cmd)

dump("click stderr sizes (post)",        f"ls -la {OUT}/*.stderr {OUT}/*.report /tmp/lb1.stderr /tmp/napt.stderr /tmp/ids.stderr")
dump("click stderr (lb1) head",          f"head -80 /tmp/lb1.stderr || true")
dump("click stderr (napt) head",         f"head -80 /tmp/napt.stderr || true")
dump("click stderr (ids) head",          f"head -80 /tmp/ids.stderr || true")

net.stop()
PYEOF

echo "[diag] killing POX"
kill -INT "$POX_PID" 2>/dev/null || true
sleep 2
kill -9 "$POX_PID" 2>/dev/null || true
killall -9 click 2>/dev/null || true
mn -c >/dev/null 2>&1 || true

echo "[diag] final dump of click reports (post-shutdown):"
ls -la "$OUT"/*.stderr "$OUT"/*.report 2>/dev/null || true
echo "[diag] done. Outputs in $OUT"
