# Project documentation (IK2221 Phase 1)

Subsystem reviews for this repository. Each page summarizes **design intent**, **how it maps to the course brief**, and **where to look in code**, informed by a pass over the tree (topology, POX, Click NFVs, build/test/VM helpers).

## Document map

| Document | Scope |
|----------|--------|
| [topology-and-testing.md](topology-and-testing.md) | Mininet `MyTopo`, addressing, `startup_services`, automated tests, LB-only topology |
| [controller-and-click-wrapper.md](controller-and-click-wrapper.md) | POX `baseController`, DPID routing, `click_wrapper` process model |
| [nfv-napt.md](nfv-napt.md) | Click NAPT: zones, ARP, TCP/ICMP rewrite, counters |
| [nfv-ids.md](nfv-ids.md) | Click IDS: three ports, HTTP policy, diversion to `insp` |
| [nfv-load-balancer.md](load_balancer.md) | Click LB: VIP, round-robin, proxy-ARP, ICMP (deep element-level notes) |
| [build-test-and-vm.md](build-test-and-vm.md) | `Makefile` targets, `phase_1_report`, VM sync/run scripts |

## System context (subsystem view)

```mermaid
flowchart TB
  subgraph topo[topology/]
    T[topology.py MyTopo + startup_services]
    TT[topology_test.py]
    TTL[topology_test_lb.py]
    TH[testing.py helpers]
  end
  subgraph app[applications/controller/]
    BC[baseController.py]
    CW[click_wrapper.py]
  end
  subgraph nfv[applications/nfv/]
    N[napt.click]
    I[ids.click]
    L[lb1.click]
  end
  subgraph run[build and ops]
    MK[Makefile]
    SH[scripts/]
  end
  T --> BC
  BC --> CW
  CW --> N & I & L
  TT --> T & TH
  TTL --> TH
  MK --> T & BC
  MK --> SH
```

For a single end-to-end path from hosts to backends, see the [root README](../README) Mermaid figures.
