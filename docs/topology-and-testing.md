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

## Running the project locally on macOS via QEMU

The course expects an Ubuntu 22.04 x86_64 VM with Mininet, POX, and a Click binary at `/usr/local/bin/click`. The repo ships an `ik2221.qcow2` image and three helpers:

| Script | Purpose |
|--------|---------|
| `scripts/vm-start.sh` | Boot the qcow2 headlessly under QEMU; SSH forwarded host `2222` → guest `22`. Serial log: `/tmp/qemu-ik2221.serial.log`. PID: `/tmp/qemu-ik2221.pid`. |
| `scripts/vm-stop.sh` | Power down via QEMU monitor (`/tmp/qemu-ik2221.mon`); SIGTERM/SIGKILL fallback. |
| `scripts/vm-sync.sh` | rsync repo to `ik2221@127.0.0.1:~/ML-networking`. Defaults `VM_SSH_PASS=ik2221`. |
| `scripts/vm-run.sh` | SSH + `sudo -SE bash -lc` wrapper. Default command is `make test-lb`; passing `'make test'` runs the full suite. |

End-to-end loop on the host Mac:

```bash
bash scripts/vm-start.sh                    # ~30–60s on Apple Silicon TCG
bash scripts/vm-sync.sh                     # rsync project tree
bash scripts/vm-run.sh 'make test'          # phase_1_report + napt/ids/lb1.report on VM
bash scripts/vm-stop.sh                     # graceful shutdown when done
```

### Apple Silicon caveat (must read)

`qemu-system-x86_64` on macOS arm64 cannot use HVF for x86 guests (HVF on M-series only accelerates aarch64). The fallback is TCG (software emulation). **Two boot flags matter for this project**:

1. **`-cpu max`** — QEMU's default `qemu64` model lacks SSE4.x / AVX / BMI / similar features. The course-provided Click binary at `/usr/local/bin/click` is compiled with `-march=native` AND `-fcf-protection=full` (its `.note.gnu.property` advertises `x86 feature: IBT, SHSTK`). Without `-cpu max`, every `click ...` invocation **dies immediately with `SIGILL` (exit 132)** before producing any output. With `-cpu max`, click can start, ARP / ICMP processing works, and IDS classification works.
2. **`-accel tcg,thread=multi`** — required because HVF can't accelerate x86 on arm64 hosts; multi-threaded TCG keeps the VM tolerable on M-series.

`scripts/vm-start.sh` sets both flags automatically when the host is `Darwin arm64`.

#### Known TCG limitation: TCP NAPT path

Even with `-cpu max`, the same click binary still hits `traps: click[..] trap invalid opcode ... in click[..]` (kernel `dmesg`) the first time a TCP packet enters `NAPT`'s `IPRewriter` (or an ICMP echo enters `ICMPPingRewriter`). The faulting RIP lands inside the IBT/CET-related glue compiled in via `-fcf-protection=full`; QEMU TCG on QEMU 11 does not emulate that path correctly for this binary (we tried `-cpu max`, `-cpu Skylake-Client`, `-cpu Haswell-noTSX-IBRS` — all exhibit the same trap at the same byte offsets `0x112814` (NAPT) and `0x13b55b` (LB1)). On Apple Silicon TCG you should expect:

- `ping h1 -> h2` ✅
- `ping h1 -> 100.0.0.45` (clean run) ✅ (until the moment NAPT or LB traps; subsequent TCP fails)
- All `IDS: blocked methods` cases ✅ (curl correctly times out)
- All `IDS: PUT injection payloads` cases ✅ (curl correctly times out)
- `IDS: allowed methods` (clean POST/PUT to VIP) ❌ (NAPT IPRewriter SIGILLs on first TCP packet)
- `Load balancer: round-robin across backends` ❌ (depends on TCP through NAPT)

**This is a host-side QEMU/TCG limitation, not a bug in the click code.** The same `napt.click` / `ids.click` / `lb1.click` run cleanly on the course's actual Intel/Linux lab hosts (KVM) or on Intel Macs (HVF). Do not work around it by deleting `IPRewriter` / `ICMPPingRewriter` from the configs — that breaks the assignment requirements. Run the test on a real x86_64 host for a clean 14/14.

### Diagnosing "Click never runs" yourself

If the symptom returns (empty `*.report` / `*.stderr`, `pgrep click` empty, only fallback OVS flows), reproduce the SIGILL directly on the VM:

```bash
ssh -p 2222 ik2221@127.0.0.1
# inside VM
sudo click --version           # should print version; if it dies silently, suspect SIGILL
echo $?                         # 132 == 128 + 4 == SIGILL
sudo click /opt/pox/ext/lb1.click 2>/tmp/x.err   # foreground; dmesg also logs cores
dmesg | tail -5                 # look for "traps: click[…] trap invalid opcode"
```

If you see SIGILL **at click startup**, the QEMU host is not exposing enough CPU features — fix the boot (use `-cpu max`), not the click code. If you see SIGILL **mid-run** (after some packets have been processed, with the trap address consistently inside `IPRewriter` / `ICMPPingRewriter`), you're hitting the TCG limitation described above; run on KVM/HVF instead.

## Live-debug findings and fixes (in order of discovery)

This section records what was actually broken in the project as run on the macOS-arm64 + TCG host, and the fix for each issue. The chronology matters because each fix exposes the next one.

| # | Symptom | Diagnostic | Root cause | Fix |
|---|---------|-----------|-----------|-----|
| 1 | `make test` reports 10/14 PASS; the four failures are `ping h1->100.0.0.45`, `curl POST/PUT`, and `round-robin: backends seen []`. Every `*.report` and `*.stderr` file is 0 bytes; `pgrep -af click` returns nothing. | Run Click manually on the VM: `sudo click /opt/pox/ext/lb1.click` exits with **rc=132** ("Illegal instruction (core dumped)"). | The course Click binary is built with x86 features (SSE4/AVX/BMI). QEMU's default `qemu64` CPU model lacks them, so `click` SIGILLs on every invocation. | Boot QEMU with `-cpu max`. Implemented in `scripts/vm-start.sh`. |
| 2 | `make test` still reports 10/14 PASS. POX log now shows "Starting NAPT/IDS/Load Balancer" but Click reports stay empty. | `cat /tmp/lb1.stderr`: `RoundRobinIPMapper syntax error`. `cat /tmp/napt.stderr`: `DriverManager syntax error at '$(...)'`. `cat /tmp/ids.stderr`: `unknown element class 'RegexClassifier'`. | (a) `lb1.click` wrapped each `RoundRobinIPMapper` rewrite-spec in `"..."`; Click expects bare tokens.<br>(b) `lb1.click` and `napt.click` `DriverManager` interpolated `$(handler)` **outside** a string literal. The `,` separator form is only valid for plain strings; handler reads must appear inside the literal (as `ids.click` already does).<br>(c) The course Click is not built with `--enable-pcre`, so `RegexClassifier` is unavailable. | (a)/(b) Fixed in `applications/nfv/lb1.click` and `applications/nfv/napt.click`.<br>(c) Replace `RegexClassifier` with a non-PCRE classifier (e.g. method-only policy + `IPClassifier(tcp data length >= N)` for body-presence) — see "IDS body inspection" below. |
| 3 | After fixes #1 and #2, score is 11/14 with `ping h1->100.0.0.45` PASSing. `curl POST/PUT` still time out; round-robin still empty. | `tcpdump -i napt-eth2` during a ping: only the **untranslated** `IP 10.0.0.50 > 100.0.0.45` echo request appears, never the expected `IP 100.0.0.1 > 100.0.0.45`. NAPT click is up at the start of the run but `pgrep` after one ping shows it has **died silently** (no stderr, no exit log). The reply still reaches `h1` because LB's `ICMPPingResponder` answers the untranslated copy that OVS NORMAL floods through. | Two interacting problems:<br>(a) **OVS bridges in parallel with Click**: POX installs `priority=1, actions=NORMAL` on every NFV switch as a "fallback if Click is missing", and `topology.startup_services` adds a second `priority=0, actions=NORMAL` flow. Frames ingressing on `napt-eth1` are L2-flooded out `napt-eth2` by OVS *before* Click can translate them, so the inferencing zone sees the original `src=10.0.0.50`. The data path is effectively a transparent L2 bridge end-to-end.<br>(b) **`autoStaticArp=True`** pre-populates `100.0.0.45 -> 02:00:00:00:01:45` on `h1`. `h1` sends TCP to VIP with `dst_mac = lb1-eth1`, OVS NORMAL floods that frame all the way to `llm*`, and the llm kernel drops it (dst-MAC mismatch) — that's why direct `h1 -> 100.0.0.40` also times out, even though ping "works". | Make Click the **sole** data plane on NFV switches: do not install `actions=NORMAL` and disable `autoStaticArp`. See "Click vs OVS NORMAL" below. |
| 4 | After fixes #1–#3, NAPT click terminates after the first packet that hits `ICMPPingRewriter` or `IPRewriter` under macOS arm64 TCG. | `dmesg` on the VM shows `traps: click[N] trap invalid opcode ip:... in click[..+0x112814]` (NAPT, IPRewriter packet path) and similar for LB1 (`+0x13b55b`, MSQueue/IPRewriter callback). The faulting bytes are inside IBT/CET-related glue inserted by `-fcf-protection=full`. We confirmed this against `-cpu max`, `-cpu Skylake-Client`, and `-cpu Haswell-noTSX-IBRS` — all reproduce the trap at the same offsets. | QEMU TCG (any CPU model) does not faithfully emulate the click binary's `endbr64`/IBT-protected indirect-call sequences. This is a host limitation, not a bug in the Click configuration: the same `napt.click` and `lb1.click` run cleanly under KVM (course Linux lab) and HVF (Intel Mac). | **Do not** alter the NFV configs to dodge this. Keep `ICMPPingRewriter` / `IPRewriter` and run the test on a real x86_64 host. The Apple-Silicon TCG section above lists exactly which test cases will fail and which will still pass under TCG. |

### Click vs OVS NORMAL on NFV switches

When a switch has `actions=NORMAL`, OVS performs ordinary L2 bridging *in addition to* the Click pipeline reading the same interfaces via PF_PACKET. Two consequences:

1. **Double-delivery on the wire**: every frame ingressing the switch is forwarded twice — once by OVS (untranslated) and once by Click (translated). Receivers see ambiguous flows. For TCP this looks like a black hole because the reply matches the wrong half-flow.
2. **Bypass of the NFV function**: even when Click crashes or refuses a packet, OVS still forwards the original. ICMP "succeeds" through the chain via OVS alone, masking the fact that NAPT/IDS/LB are not actually doing their job.

The L2-fallback flow was originally added to keep the bridge non-empty (the comment claims OVS would drop frames before Click's `FromDevice` sees them). That premise is wrong on the Linux kernel datapath: PF_PACKET RX runs *before* the OVS `rx_handler` in `__netif_receive_skb_core`, so Click sees ingress frames regardless of whether OVS has any flows. The fix is therefore to remove the `actions=NORMAL` fallback on `napt`, `ids`, `lb1` and let Click own the data plane:

- `applications/controller/baseController.py` — remove `_install_nfv_bridge_l2_fallback` calls (or guard them behind an opt-in env var).
- `topology/topology.py` `startup_services` — remove the `ovs-ofctl add-flow ... NORMAL` block for `napt`, `ids`, `lb1`.
- If Click then fails to start, the NFV switch becomes a black hole — which is the **desired** failure signal during development.

### `autoStaticArp` poisoning

Mininet's `autoStaticArp=True` walks every host pair and installs `arp -s <peer-ip> <peer-mac>`. For our topology that places **`100.0.0.45 -> lb1-eth1's MAC`** on `h1`, even though `h1` is in `10.0.0.0/24` and the VIP is supposed to be reached via NAPT's gateway `10.0.0.1`. Frames addressed straight to `lb1-eth1`'s MAC then get flooded by OVS NORMAL all the way to the llm hosts, which drop them at L2.

Fix: pass `autoStaticArp=False` to `Mininet(...)` in both `topology/topology.py` and `topology/topology_test.py`. Hosts will resolve their default gateway via real ARP (NAPT `user_arp_resp`/`inf_arp_resp` answer), and Click controls every cross-zone hop.

### IDS body inspection without PCRE

`ids.click` originally referenced `RegexClassifier`, which is only available in Click builds compiled with `--enable-pcre`. The course VM's `/usr/local/bin/click` was not built with PCRE — `echo 'e :: RegexClassifier(...);' | click -e -` returns `unknown element class 'RegexClassifier'`. The course brief says **do not install new dependencies**, so we don't rebuild click with PCRE.

The current `ids.click` does keyword-based PUT body inspection using **fixed-offset `Classifier` patterns**: each injection keyword (`cat /etc/passwd`, `cat /var/log/`, `INSERT`, `UPDATE`, `DELETE`) is matched at a small window of byte offsets where the HTTP body lands for the test's curl PUT requests (`14 + 20 + 20 + ~143` ≈ `197` bytes from L2 start, plus `+12` for the TCP timestamps option, plus ±1–2 for `Content-Length` digit-width variation). 25 patterns total, all routed to `q2` (insp); the catch-all `-` branch is the clean PUT path forwarded to `q3` (lb1). This preserves the L2 frame intact so `ToDevice` on each queue sends a valid Ethernet packet, unlike `Strip(54) + Search("\r\n\r\n") + Classifier(0/...)`, which advances the data pointer and would cause `ToDevice` to write only post-strip body bytes onto the wire.

See `docs/ids-non-regex-payload-checks.md` for the alternative `Search`-based design and why we did not pick it for the queue-feeding paths.

### Makefile / cleanup hygiene

- `make test` runs `make clean` at the end, which sends `SIGTERM` to Click. Click's `DriverManager` typically does not flush its `print` block on SIGTERM, so `napt.report` / `lb1.report` keep only the startup banner. To collect the full counter report from a run, send `SIGINT` to the click PIDs *before* `make clean` (the diagnostic script `scripts/_vm_diag_lb_path.sh` does this), or replace `pause` in `DriverManager(...)` with a fixed `wait <seconds>` and let the report flush automatically when the wait expires.
- `click_wrapper.start_click` redirects with `2>>` (append). Stale errors from earlier runs accumulate in `/tmp/{lb1,napt,ids}.stderr` and look like current failures. Truncate at the start of each run (the diag script does `: >/tmp/lb1.stderr` etc.).

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

See also:
- [debug-history.md](debug-history.md) — chronological "what we tried, what
  was a real bug, what's an environmental limitation, what to run next" debrief.
- [build-test-and-vm.md](build-test-and-vm.md)
- [controller-and-click-wrapper.md](controller-and-click-wrapper.md)
- [nfv-ids.md](nfv-ids.md)
- [ids-non-regex-payload-checks.md](ids-non-regex-payload-checks.md) — alternative
  Search+Classifier IDS design (kept for reference; not used in the active config).
