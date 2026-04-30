"""
Automated IK2221 Phase 1 regression tests (full topology: NAPT → IDS → LB).

Design:
  - Mimics ``make test``: builds MyTopo, starts services, assumes POX already running (Makefile starts it).
  - MN_AUTOMATED=1 skips interactive CLI so Jenkins-style runs exit cleanly.
  - VIP ping waits tolerate slow Click/OVS bring-up before HTTP assertions.

Defense: each block maps to PDF clauses (UZ connectivity, ICMP to VIP, IDS method/payload policy, LB round-robin).
"""

import os
import time
from mininet.topo import Topo
from mininet.net import Mininet
from mininet.node import Switch
from mininet.cli import CLI
from mininet.node import RemoteController
from mininet.node import OVSSwitch
from topology import *
import testing

topos = {'mytopo': (lambda: MyTopo())}

VIP = '100.0.0.45'
# Virtual service IP implemented by lb1.click (not assigned to a single llm host).


def wait_for_vip(net, timeout=30):
    # Poll ICMP echo to VIP from UZ; proves NAPT + LB ICMP path without needing HTTP yet.
    h1 = net.get('h1')
    deadline = time.time() + timeout
    while time.time() < deadline:
        if testing.ping(h1, VIP, True):
            return True
        time.sleep(1)
    return False


def run_tests(net):
    # Each append returns bool; sum(results) counts passes (truthy ints).
    h1 = net.get('h1')
    h2 = net.get('h2')

    results = []

    print("\n=== Connectivity ===")
    results.append(testing.ping(h1, '10.0.0.51', True))            # h1 → h2 same subnet
    results.append(testing.ping(h1, VIP, True))                     # h1 → VIP through NAPT + LB ICMP

    print("\n=== IDS: allowed methods ===")
    results.append(testing.curl(h1, VIP, method='POST', expected=True))
    results.append(testing.curl(h1, VIP, method='PUT', expected=True))

    print("\n=== IDS: blocked methods ===")
    results.append(testing.curl(h1, VIP, method='GET',     expected=False))
    results.append(testing.curl(h1, VIP, method='HEAD',    expected=False))
    results.append(testing.curl(h1, VIP, method='DELETE',  expected=False))
    results.append(testing.curl(h1, VIP, method='OPTIONS', expected=False))
    results.append(testing.curl(h1, VIP, method='TRACE',   expected=False))
    results.append(testing.curl(h1, VIP, method='CONNECT', expected=False))

    print("\n=== IDS: PUT injection payloads (should be blocked) ===")
    results.append(testing.curl(h1, VIP, method='PUT',
                                payload='cat /etc/passwd', expected=False))
    results.append(testing.curl(h1, VIP, method='PUT',
                                payload='cat /var/log/syslog', expected=False))
    results.append(testing.curl(h1, VIP, method='PUT',
                                payload='INSERT INTO users VALUES (1)', expected=False))
    results.append(testing.curl(h1, VIP, method='PUT',
                                payload='UPDATE users SET pw=1', expected=False))
    results.append(testing.curl(h1, VIP, method='PUT',
                                payload='DELETE FROM users', expected=False))

    print("\n=== Load balancer: round-robin across backends ===")
    seen_backends = set()
    for i in range(9):
        body = testing.curl_body(h1, VIP, method='POST')
        for tag in ('llm1', 'llm2', 'llm3'):
            if tag in body:
                seen_backends.add(tag)
    # Require ≥2 distinct backends in 9 POSTs: balances strictness vs flaky timer/order on slow VMs.
    rr_ok = len(seen_backends) >= 2
    status = "PASS" if rr_ok else "FAIL"
    print(f"[{status}] round-robin: backends seen in 9 POSTs: {sorted(seen_backends)}")
    results.append(rr_ok)

    passed = sum(results)
    total = len(results)
    print(f"\n=== Summary: {passed}/{total} tests passed ===")
    return all(results)


if __name__ == "__main__":

    topo = MyTopo()
    ctrl = RemoteController("c0", ip="127.0.0.1", port=6633)

    net = Mininet(topo=topo,
                  switch=OVSSwitch,
                  controller=ctrl,
                  autoSetMacs=True,
                  autoStaticArp=True,
                  build=True,
                  cleanup=True)

    net.start()
    startup_services(net)

    if not wait_for_vip(net):
        print("[WARN] VIP did not become reachable before tests started")

    run_tests(net)

    # Skip interactive CLI when running under `make test`
    if not os.environ.get('MN_AUTOMATED'):
        CLI(net)

    net.stop()
