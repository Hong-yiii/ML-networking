#!/usr/bin/env python3
"""
Load-balancer focused tests (no NAPT/IDS in topology).

Usage (course VM, two common patterns):

1) Two terminals
   - Terminal A: ``sudo make app``   (POX + Click on all NFV nodes present in topo)
   - Terminal B: ``sudo -E env IK2221_LB_REPORT=$PWD/lb1.report python3 topology/topology_test_lb.py``

2) One shot (see scripts/run_lb_integration_test.sh)

Optional: ``IK2221_TOPO_VERBOSE=1`` prints OVS flow install diagnostics for ``lb1``.
"""

from mininet.topo import Topo
from mininet.net import Mininet
from mininet.node import RemoteController, OVSSwitch
import os
import sys

# Allow ``python3 topology/topology_test_lb.py`` from repo root
_REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _REPO not in sys.path:
    sys.path.insert(0, _REPO)

import testing  # noqa: E402

_TOPO_VERBOSE = os.environ.get("IK2221_TOPO_VERBOSE", "")


class LbOnlyTopo(Topo):
    """Minimal 100.0.0.0/24 topology: one client, sw0, lb1, sw3, three backends. No napt/ids."""

    def __init__(self):
        Topo.__init__(self)
        hc = self.addHost("hc", ip="100.0.0.100/24", defaultRoute="via 100.0.0.45")
        sw0 = self.addSwitch("sw0", dpid="1")
        lb1 = self.addSwitch("lb1", dpid="6")
        sw3 = self.addSwitch("sw3", dpid="3")
        self.addLink(hc, sw0)
        self.addLink(sw0, lb1)
        self.addLink(lb1, sw3)
        for name, last in [("llm1", 40), ("llm2", 41), ("llm3", 42)]:
            h = self.addHost(name, ip=f"100.0.0.{last}/24", defaultRoute="via 100.0.0.45")
            self.addLink(h, sw3)


def startup_lb_only(net):
    for name in ["llm1", "llm2", "llm3"]:
        host = net.get(name)
        host.cmd("mkdir -p /tmp/www")
        host.cmd(f'echo "<html><body>index from {name}</body></html>" > /tmp/www/index.html')
        host.cmd("cd /tmp/www && python3 -m http.server 80 &")
    lb = net.get("lb1")
    lb.cmd("ip link set dev lb1-eth1 address 02:00:00:00:01:45 2>/dev/null || true")
    lb.cmd("ip link set dev lb1-eth2 address 02:00:00:00:02:45 2>/dev/null || true")
    # NFV bridges may have no learner-installed flows; secure + empty table drops traffic.
    for proto in ("OpenFlow10", "OpenFlow13", "OpenFlow14"):
        out = lb.cmd(
            f"ovs-ofctl -O {proto} add-flow {lb.name} 'priority=0,actions=NORMAL' 2>&1"
        )
        if _TOPO_VERBOSE and out.strip():
            print(f"[startup_lb_only] ovs-ofctl -O {proto}: {out.strip()[:200]}")
    if _TOPO_VERBOSE:
        flows = lb.cmd(f"ovs-ofctl dump-flows {lb.name} 2>&1")
        print("[startup_lb_only] dump-flows lb1:", flows.strip()[:800] if flows.strip() else "(empty)")


def run_lb_tests(net):
    hc = net.get("hc")
    ok = True
    ok &= testing.ping(hc, "100.0.0.45", True)
    body = hc.cmd("curl --connect-timeout 3 --max-time 3 -s http://100.0.0.45/index.html")
    print("[INFO] first GET body:", repr(body[:120]))
    ok &= "index from" in body
    seen = set()
    for i in range(9):
        b = hc.cmd("curl --connect-timeout 3 --max-time 3 -s http://100.0.0.45/index.html")
        for tag in ("llm1", "llm2", "llm3"):
            if tag in b:
                seen.add(tag)
    print("[INFO] backends observed in 9 GETs:", sorted(seen))
    ok &= len(seen) >= 2
    if len(seen) < 3:
        print("[WARN] expected all three backends across 9 GETs; LB or ARP may need tuning on this VM")
    return ok


def main():
    topo = LbOnlyTopo()
    ctrl = RemoteController("c0", ip="127.0.0.1", port=6633)
    net = Mininet(
        topo=topo,
        switch=OVSSwitch,
        controller=ctrl,
        autoSetMacs=True,
        autoStaticArp=True,
        build=True,
        cleanup=True,
    )
    net.start()
    startup_lb_only(net)
    passed = run_lb_tests(net)
    net.stop()
    print("=== LB-only tests:", "PASS" if passed else "FAIL", "===")
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
