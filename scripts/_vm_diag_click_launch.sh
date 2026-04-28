#!/usr/bin/env bash
# Reproduce click_wrapper.start_click manually inside a live Mininet topology,
# so we can see exactly why click dies (or whether it stays up).
set -uo pipefail
OUT=/tmp/diag-click-launch
rm -rf "$OUT" && mkdir -p "$OUT"
exec > >(tee "$OUT/diag.log") 2>&1
cd /home/ik2221/ML-networking

echo "[diag] cleaning leftover state"
pkill -9 -f 'pox.py baseController' 2>/dev/null || true
killall -9 click 2>/dev/null || true
mn -c >/dev/null 2>&1 || true
sleep 1

echo "[diag] copying click sources to /opt/pox/ext/"
cp applications/controller/* /opt/pox/ext/
cp applications/nfv/*.click /opt/pox/ext/

echo "[diag] starting POX in background WITHOUT click_wrapper (we'll launch click manually)"
# Use a stripped baseController that only does LearningSwitch + L2 fallback, no click.
cat >/tmp/_pass_through.py <<'PYEOF'
from pox.core import core
import pox.openflow.libopenflow_01 as of
from forwarding.l2_learning import LearningSwitch
log = core.getLogger()
class controller(object):
    devices = dict()
    def __init__(self):
        core.openflow.addListeners(self)
    def _normal(self, conn):
        msg = of.ofp_flow_mod()
        msg.priority = 1
        try: normal_port = of.OFPP_NORMAL
        except AttributeError: normal_port = 0xFFFA
        msg.actions.append(of.ofp_action_output(port=normal_port))
        conn.send(msg)
    def _handle_ConnectionUp(self, event):
        id = event.dpid
        if id <= 3:
            log.info(f"LearningSwitch dpid {id}")
            self.devices[id] = LearningSwitch(event.connection, False)
        else:
            log.info(f"NORMAL fallback dpid {id}")
            self._normal(event.connection)
def launch():
    core.registerNew(controller)
PYEOF
cp /tmp/_pass_through.py /opt/pox/ext/pass_through.py

python /opt/pox/pox.py pass_through >"$OUT/pox.stdout" 2>&1 &
POX_PID=$!
echo "[diag] POX pid=$POX_PID"
sleep 3

echo "[diag] building Mininet"
python3 - <<'PYEOF' >"$OUT/mininet.log" 2>&1
import sys, time, subprocess
sys.path.insert(0, "/home/ik2221/ML-networking")
sys.path.insert(0, "/home/ik2221/ML-networking/topology")
from mininet.net import Mininet
from mininet.node import RemoteController, OVSSwitch
from topology import MyTopo, startup_services
topo = MyTopo()
ctrl = RemoteController("c0", ip="127.0.0.1", port=6633)
net = Mininet(topo=topo, switch=OVSSwitch, controller=ctrl,
              autoSetMacs=True, autoStaticArp=True, build=True, cleanup=True)
net.start()
startup_services(net)
time.sleep(3)

OUT = "/tmp/diag-click-launch"

def shell(cmd):
    r = subprocess.run(["bash","-lc",cmd], capture_output=True, text=True)
    print(f"$ {cmd}\n{r.stdout}", end="")
    if r.stderr:
        print(f"  stderr> {r.stderr}", end="")
    return r

print("\n=== ip link list (root ns) ===", flush=True)
shell("ip -br link | grep -E 'lb1|napt|ids' || true")

print("\n=== launch click manually for lb1 (mirrors click_wrapper) ===", flush=True)
print("=== run as root, no sudo, capture stderr in foreground first ===", flush=True)
shell(f"timeout 2 click /opt/pox/ext/lb1.click 2>{OUT}/lb1.fg.stderr; echo rc=$?")
print(f"--- /tmp/diag-click-launch/lb1.fg.stderr ---", flush=True)
shell(f"head -80 {OUT}/lb1.fg.stderr")

print("\n=== same for napt.click ===", flush=True)
shell(f"timeout 2 click /opt/pox/ext/napt.click 2>{OUT}/napt.fg.stderr; echo rc=$?")
shell(f"head -80 {OUT}/napt.fg.stderr")

print("\n=== same for ids.click ===", flush=True)
shell(f"timeout 2 click /opt/pox/ext/ids.click 2>{OUT}/ids.fg.stderr; echo rc=$?")
shell(f"head -80 {OUT}/ids.fg.stderr")

print("\n=== exact replication of click_wrapper command ===", flush=True)
cmd = f"sudo click /opt/pox/ext/lb1.click   >{OUT}/lb1.bg.out 2>>{OUT}/lb1.bg.err &"
shell(cmd)
shell("sleep 2; pgrep -af click; echo '---'; ls -la "+OUT+"/lb1.bg.*")

print("\n=== if click is alive, do a ping and see counters ===", flush=True)
h1 = net.get('h1')
print("h1 ping VIP:", flush=True)
print(h1.cmd("ping -W 2 -c 2 100.0.0.45"))

shell("pgrep -af click")
shell("killall -9 click 2>/dev/null || true")
shell("sleep 1; ls -la "+OUT+"/lb1.bg.*; echo '--- bg out ---'; head -80 "+OUT+"/lb1.bg.out; echo '--- bg err ---'; head -80 "+OUT+"/lb1.bg.err")

net.stop()
PYEOF

echo "[diag] stopping POX"
kill -INT "$POX_PID" 2>/dev/null || true
sleep 2
kill -9 "$POX_PID" 2>/dev/null || true
mn -c >/dev/null 2>&1 || true
echo "[diag] done. Outputs in $OUT"
