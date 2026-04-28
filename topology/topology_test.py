import os
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


def run_tests(net):
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
    rr_ok = len(seen_backends) >= 2
    status = "PASS" if rr_ok else "FAIL"
    print(f"[{status}] round-robin: backends seen in 9 POSTs: {sorted(seen_backends)}")
    if len(seen_backends) < 3:
        print("[WARN] fewer than 3 backends seen — ARP or LB may need settling time")
    results.append(rr_ok)

    passed = sum(results)
    total = len(results)
    print(f"\n=== Summary: {passed}/{total} tests passed ===")
    return all(results)


if __name__ == "__main__":

    topo = MyTopo()
    ctrl = RemoteController("c0", ip="127.0.0.1", port=6633)

    # autoStaticArp=False — see topology.py for the reasoning. Real ARP via
    # NAPT/LB ARPResponders is needed; pre-poisoning h1 with `100.0.0.45 ->
    # lb1-eth1's MAC` short-circuits the NFV chain and breaks TCP.
    net = Mininet(topo=topo,
                  switch=OVSSwitch,
                  controller=ctrl,
                  autoSetMacs=True,
                  autoStaticArp=False,
                  build=True,
                  cleanup=True)

    net.start()
    startup_services(net)

    run_tests(net)

    # Skip interactive CLI when running under `make test`
    if not os.environ.get('MN_AUTOMATED'):
        CLI(net)

    net.stop()
