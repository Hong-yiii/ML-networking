# IK2221 Phase 1 — status and backlog

Single place to see **what works**, **what fails**, **what’s left**, and **what was already explored** so the next iteration starts from a clean baseline.

---

## Already in place (done)

- **Topology (`topology/topology.py`)**  
  Full brief-style graph: UZ (`h1`, `h2`, `sw1`), `napt` (dpid 4), `sw2`, `ids` (dpid 5), `insp`, `lb1` (dpid 6), `sw3`, `llm1`–`llm3`. LLMs and `insp` on `100.0.0.0/24` with routes via VIP where configured.
- **`startup_services`**  
  HTTP on `llm*`, `tcpdump` on `insp`, fixed `lb1` Ethernet MACs to match `lb1.click`, **OVS** `NORMAL` flow install attempts on `lb1`, `napt`, `ids` (so empty secure tables do not drop all traffic).
- **Load balancer Click (`applications/nfv/lb1.click`)**  
  VIP `100.0.0.45`, ARP for VIP, proxy-ARP on server side, `ICMPPingResponder`, `IPRewriter` + `RoundRobinIPMapper` to `100.0.0.40–42:80`, counters and `DriverManager` report.
- **Controller (`applications/controller/baseController.py`)**  
  LearningSwitch for dpid 1–3; Click for 4/5/6; **`_install_nfv_bridge_l2_fallback`**: OpenFlow flow with **`OFPP_NORMAL`** on NFV connections so kernel L2 runs alongside the bridge.
- **Stubs**  
  `napt.click` / `ids.click` as transparent L2 paths for LB-focused work.
- **LB-only test topo (`topology/topology_test_lb.py`)**  
  `hc`, `sw0`, `lb1`, `sw3`, three backends; same MAC + OVS `NORMAL` bootstrap on `lb1`.
- **Integration**  
  `scripts/run_lb_integration_test.sh`: copies into POX `ext/`, starts POX (correct **`…/pox.py`** path), **`IK2221_POX_WARMUP_SEC`** (default 20s), runs tests, **on failure** prints tail of **`/tmp/lb1.stderr`**.
- **Host ↔ VM**  
  `scripts/vm-sync.sh`, `scripts/vm-ssh-exec.sh`, `scripts/vm-run.sh`; **Makefile** targets `vm-sync`, `vm-test-lb`.
- **Docs** under `docs/` (architecture, LB, NAPT/IDS notes, VM/build).

---

## Passing vs failing (current)

| Check | Status | Notes |
|--------|--------|--------|
| POX boots; switches connect; Click `lb1` PID starts | **Passing** | Observed in VM logs. |
| **`lb1` OVS has flows; counters advance** | **Passing** | `dump-flows` showed `priority=1` + `priority=0` `NORMAL`; non-zero `n_packets` before tests. |
| **`click-check applications/nfv/lb1.click`** (syntax) | **Assumed OK** | Run on course VM when debugging. |
| **`make test-lb` / `topology_test_lb.py`** | **Failing** | **`ping hc → 100.0.0.45`** fails; first **HTTP GET** body empty; round-robin not satisfied. |
| **`make test` (full chain + `topology_test.py`)** | **Unknown / likely partial** | Full NAPT/IDS behaviour not finalized; depends on stubs vs real NFV. |

**Strong symptom from last runs:** on `hc`, neighbour state for **`100.0.0.45`** stayed **`INCOMPLETE`** (no learned Ethernet address for the VIP). That points to **ARP not completing on the client path**, and/or **frames not reaching/consistently handled by Click** after OVS. A one-off **static neighbour** experiment still did not yield a passing ping in automation—so **ICMP through the LB path** may still be wrong or unreachable even when ARP is forced.

---

## Left to do (priority order)

1. **LB data path end-to-end**  
   - Confirm **ARP requests** reach **Click** (`cnt_arp_req_c` / `lb1.report` / `tcpdump` on `lb1` / `hc`).  
   - Confirm **ICMP echo** classification matches this **Click** build (`IPClassifier` / `ICMPPingResponder`).  
   - Validate **TCP VIP:80** rewrite and return path; then **nine GETs** for round-robin.
2. **Full topology tests (`make test`)**  
   Align **`topology_test.py`** scenarios with the PDF (methods, IDS diversion, `phase_1_report`, report paths).
3. **Real `napt.click` and `ids.click`**  
   Replace stubs per spec (NAPT, inspection, `insp`, etc.).
4. **Hand-in hygiene**  
   Folder names/layout vs Canvas; collect **`napt.report`**, **`ids.report`**, **`lb1.report`**, **`phase_1_report`**.

---

## Investigation already done (no need to repeat blindly)

These were tried during LB test debugging; they are **kept in tree** only where they are intentional infrastructure (not throwaway hacks):

| Item | Result |
|------|--------|
| **POX path** in `run_lb_integration_test.sh` (`${POXDIR%/}/pox.py`) | **Bug fix** — previously launched `/opt/poxpox.py`. |
| **Longer POX/Click warmup** (`IK2221_POX_WARMUP_SEC`, default 20s) | **Kept**; did not alone fix ping. |
| **NFV OVS empty flow table** | **Mitigations kept:** `OFPP_NORMAL` from **POX** on dpids 4/5/6; **`ovs-ofctl add-flow … actions=NORMAL`** from **Mininet** startup for `lb1` (LB test) and `lb1`/`napt`/`ids` (full topo). |
| **`FromDevice` SNIFFER true vs false** | Toggled in testing; **current `lb1.click` uses `SNIFFER false`** per brief-style setup. |
| **`IPClassifier`**: `icmp type echo` vs broader `icmp` | **Current:** `dst host $VIP and icmp` (broader). |
| **Static neighbour on `hc` for VIP MAC** | **Removed from tests** — was diagnostic only; should not fake ARP in the real test. |
| **SSH/rsync VM loop** | **Kept** as `vm-sync` / `vm-run`; useful for iterating on the course VM. |

**Suggested next diagnostics (fresh):** on the VM, during a failed run, inspect **`/tmp/lb1.stderr`**, **`lb1.report`** (counter section), **`ovs-ofctl dump-flows lb1`**, and ** packet trace** on **`hc`** and **`lb1`** for ARP/ICMP.

---

## Observability (kept on purpose)

- **`topology_test_lb.py`:** **`[INFO]`** / **`[WARN]`** for first GET preview, backends seen, round-robin warning.  
- Optional: set **`IK2221_TOPO_VERBOSE=1`** to print **`ovs-ofctl`** messages and **`dump-flows`** for `lb1` during LB-only startup.  
- **`run_lb_integration_test.sh`:** on non-zero exit, prints **`tail` of `/tmp/lb1.stderr`**.  
- **Click:** stderr **`/tmp/lb1.stderr`**, report path from **`IK2221_LB_REPORT`** (e.g. **`lb1.report`**).

---

*Last updated from repo state and VM test logs (LB integration still failing until VIP ARP/ICMP/path is fixed end-to-end).*
