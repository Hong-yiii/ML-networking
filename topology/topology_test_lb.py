#!/usr/bin/env python3
"""
Load-balancer focused tests (no NAPT/IDS in topology).

Purpose:
  Isolate lb1.click + backends on a flat 100.0.0.0/24 so LB/ARP/rewriter bugs are debuggable without
  NAPT or IDS in the path. DPIDs still use 6 for lb1 and 3 for sw3 so the same POX branch starts Click.

Usage (course VM, two common patterns):

1) Two terminals
   - Terminal A: ``sudo make app``   (POX + Click on all NFV nodes present in topo)
   - Terminal B: ``sudo -E env IK2221_LB_REPORT=$PWD/lb1.report python3 topology/topology_test_lb.py``

2) One shot (see scripts/run_lb_integration_test.sh)
"""

from mininet.topo import Topo
from mininet.net import Mininet
from mininet.node import RemoteController, OVSSwitch
import os
import sys

# Allow ``python3 topology/topology_test_lb.py`` from repo root (imports sibling ``topology`` / ``testing``).
_REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _REPO not in sys.path:
    sys.path.insert(0, _REPO)

import testing  # noqa: E402


class LbOnlyTopo(Topo):
    """Minimal 100.0.0.0/24 topology: one client, sw0, lb1, sw3, three backends. No napt/ids."""

    def __init__(self):
        Topo.__init__(self)
        # Client sits on IZ subnet in this mock; default via VIP matches backend routing model in full topo.
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
    def start_backend_server(host, name):
        host.cmd("mkdir -p /tmp/www")
        host.cmd(f'echo "<html><body>index from {name}</body></html>" > /tmp/www/index.html')
        host.cmd(f"cat > /tmp/www/server.py <<'PY'\nfrom http.server import BaseHTTPRequestHandler, HTTPServer\n\nBODY = b\"<html><body>index from {name}</body></html>\"\n\nclass Handler(BaseHTTPRequestHandler):\n    def _send_body(self):\n        self.send_response(200)\n        self.send_header('Content-Type', 'text/html')\n        self.send_header('Content-Length', str(len(BODY)))\n        self.end_headers()\n        self.wfile.write(BODY)\n\n    def do_GET(self):\n        self._send_body()\n\n    def do_POST(self):\n        self._send_body()\n\n    def log_message(self, format, *args):\n        pass\n\nHTTPServer(('0.0.0.0', 80), Handler).serve_forever()\nPY")
        host.cmd(f'nohup python3 /tmp/www/server.py >/tmp/{name}.http.log 2>&1 < /dev/null &')

    def wait_for_backend(host, name):
        for _ in range(20):
            body = host.cmd("curl --connect-timeout 1 --max-time 1 -s http://127.0.0.1/index.html")
            if f"index from {name}" in body:
                return True
        print(f"[WARN] backend {name} did not become ready in time")
        return False

    ready = True
    for name in ["llm1", "llm2", "llm3"]:
        host = net.get(name)
        start_backend_server(host, name)
        ready &= wait_for_backend(host, name)
    lb = net.get("lb1")
    lb.cmd("ip link set dev lb1-eth1 address 02:00:00:00:01:45 2>/dev/null || true")
    lb.cmd("ip link set dev lb1-eth2 address 02:00:00:00:02:45 2>/dev/null || true")
    if not ready:
        print("[WARN] one or more backends were not ready before the LB test started")


def http_get_body(host, url):
    return host.cmd(
        f"curl --connect-timeout 3 --max-time 5 -sS {url}"
    )


def run_lb_tests(net):
    # Stricter than full topo test: require all three backends across 25 GETs (LB-only harness has no IDS variance).
    hc = net.get("hc")
    ok = True
    ok &= testing.ping(hc, "100.0.0.45", True)
    seen = set()
    body = ""
    for _ in range(5):
        body = http_get_body(hc, "http://100.0.0.45/index.html")
        if "index from" in body:
            break
    print("[INFO] first GET body:", repr(body[:120]))
    ok &= "index from" in body
    for tag in ("llm1", "llm2", "llm3"):
        if tag in body:
            seen.add(tag)
    for i in range(24):
        b = http_get_body(hc, "http://100.0.0.45/index.html")
        for tag in ("llm1", "llm2", "llm3"):
            if tag in b:
                seen.add(tag)
    print("[INFO] backends observed in 25 GETs:", sorted(seen))
    ok &= len(seen) == 3
    if len(seen) < 3:
        print("[WARN] expected all three backends across 25 GETs; LB or ARP may need tuning on this VM")
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
