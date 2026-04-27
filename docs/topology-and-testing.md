# Topology and testing

This document describes the **Mininet layout**, **host configuration**, and **automated test harness**. It reflects the project topology and tests under `topology/`.

## Design role (course brief)

The assignment specifies a **User Zone** (`10.0.0.0/24`) and an **Inferencing Zone** (`100.0.0.0/24`), connected by a **NAPT**, with an **IDS** before the **load balancer** and a **virtual service IP** `100.0.0.45` for HTTP. The topology file is the **ground truth** for link order, DPIDs, and default routes that the Click modules and POX assume.

## `MyTopo` — switches and DPIDs

Construction order and DPIDs (must stay aligned with `applications/controller/baseController.py`):

| Node | DPID | Role |
|------|------|------|
| `sw1` | 1 | User-zone L2 (POX learning switch) |
| `sw2` | 2 | Inferencing access L2 |
| `sw3` | 3 | L2 toward LLM servers |
| `napt` | 4 | NFV: Click NAPT |
| `ids` | 5 | NFV: Click IDS |
| `lb1` | 6 | NFV: Click load balancer |

## Link chain

Logical service path:

`h1` / `h2` → `sw1` → `napt` → `sw2` → `ids` → `lb1` → `sw3` → `llm1` / `llm2` / `llm3`

The inspector host `insp` attaches to `ids` (sink for suspicious traffic redirected by the IDS Click module).

## Host addressing and default routes

Defined in `topology/topology.py`:

| Host | Address | Default route |
|------|---------|----------------|
| `h1`, `h2` | `10.0.0.50/24`, `10.0.0.51/24` | `via 10.0.0.1` (NAPT user-side logical IP) |
| `insp` | `100.0.0.30/24` | `via 100.0.0.1` |
| `llm1`–`llm3` | `100.0.0.40–42/24` | `via 100.0.0.45` (VIP on LB) |

## `startup_services(net)`

Runs after `net.start()` when using the interactive `topology.py` entrypoint:

- **HTTP**: `python3 -m http.server 80` on `llm1`–`llm3` with small pages under `/tmp/www`.
- **Inspector evidence**: `tcpdump -i insp-eth0 -w /tmp/insp_capture.pcap` on `insp`.
- **LB MAC alignment**: `lb1-eth1` → `02:00:00:00:01:45`, `lb1-eth2` → `02:00:00:00:02:45` to match `lb1.click` `AddressInfo` / ARP behavior.

## Automated mode: `MN_AUTOMATED`

`make test` sets `MN_AUTOMATED=1` when invoking `topology/topology_test.py`. When set, the Mininet **CLI is skipped** after tests so the run exits cleanly in CI-style automation.

## Test helpers — `topology/testing.py`

- `ping(client, server, expected, ...)` — compares ping success to an expected boolean.
- `curl(...)` — HTTP fetch via `curl`, treats exit code 0 as success.
- `curl_body(...)` — returns response body for assertions (e.g. round-robin).

## Full-chain tests — `topology/topology_test.py`

`VIP = '100.0.0.45'`. `run_tests(net)` roughly covers:

- Basic **UZ** ping (`h1` ↔ `h2`).
- **Ping VIP** (validates LB ICMP path per brief).
- **IDS method policy**: `POST` and `PUT` expected to succeed; `GET`, `HEAD`, `DELETE`, `OPTIONS` expected to fail toward the service.
- **Injection-style PUT bodies**: strings matching the brief’s examples expected to fail (blocked / diverted).
- **Load balancing**: multiple `POST`s to the VIP; response bodies should show at least **two** distinct backend hostnames (`llm1`/`llm2`/`llm3`) in the current assertion (not a strict “all three within N tries”).

Exit: `run_tests` returns whether all boolean checks passed.

## LB-only tests — `topology/topology_test_lb.py`

A smaller topology (`LbOnlyTopo`) with a single client host, **`sw1`** (learning) plus **`lb1`** and **`sw3`**, **no** `napt`/`ids`. Used by `make test-lb` / `scripts/run_lb_integration_test.sh` to isolate load-balancer behavior.

## Gaps and grader-facing notes

| Topic | Note |
|--------|------|
| PCAP proof | `tcpdump` writes `/tmp/insp_capture.pcap`; automated tests do not currently parse the PCAP (manual verification possible). |
| HTTP method matrix | Tests cover several disallowed methods; not every method named in the brief (e.g. TRACE/CONNECT) may be exercised—extend `topology_test.py` if you need full coverage. |
| Round-robin strictness | Assertion uses “≥ 2 backends seen” with a warning path if fewer than three appear in the sample size. |

## Key files

- `topology/topology.py` — `MyTopo`, `startup_services`, CLI entry.
- `topology/topology_test.py` — full-path automated scenarios.
- `topology/topology_test_lb.py` — LB-only topology and tests.
- `topology/testing.py` — shared ping/curl helpers.

See also: [build-test-and-vm.md](build-test-and-vm.md), [controller-and-click-wrapper.md](controller-and-click-wrapper.md), [nfv-ids.md](nfv-ids.md).
