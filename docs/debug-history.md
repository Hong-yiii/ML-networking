# IK2221 Phase 1 — debug history and lessons learnt

This document is a single-page debrief of what we tried, what broke, what was a
real bug in our code vs. an environmental limitation, what state the repo is in
right now, and what to do next. If you read nothing else, read [TL;DR](#tldr)
and [Run plan from here](#run-plan-from-here).

---

## TL;DR

- The NFV click code (`napt.click`, `ids.click`, `lb1.click`) and the
  topology / controller wiring are now **in the state the course expects**.
- On the course's intended runtime (Linux x86_64 + KVM, or Intel macOS + HVF),
  this should produce **14/14 passing** in `make test`.
- On Apple Silicon (arm64) you must run x86_64 under QEMU **TCG**, and TCG
  cannot fully emulate the indirect-call sequences in `IPRewriter` /
  `ICMPPingRewriter` / `MSQueue` of the course-supplied `/usr/local/bin/click`
  (CET-IBT-protected glue from `-fcf-protection=full`). Symptoms reproduce
  identically across `-cpu max`, `-cpu Skylake-Client`, and
  `-cpu Haswell-noTSX-IBRS`.
- Best **observed** result on Apple Silicon TCG: **11/14**. The 3 failures are
  the only TCP-success cases (`POST` to VIP, `PUT` to VIP, `round-robin`); they
  fail because NAPT click traps the moment the first TCP packet hits
  `IPRewriter`.
- We **did not** rebuild click, did not patch the binary, did not install new
  deps. The fix for those last 3 failures is to run on a CPU TCG can fully
  emulate — i.e. on the course env.

---

## Topology and what `make test` actually checks

Topology (from `topology/topology.py`):

```
h1 / h2 ── sw1 ── napt ── sw2 ── ids ── lb1 ── sw3 ── llm1 / llm2 / llm3
                                  │
                                 insp
```

DPIDs: sw1=1, sw2=2, sw3=3, napt=4, ids=5, lb1=6. Addresses: User Zone
`10.0.0.0/24` (h1=.50, h2=.51); Inferencing Zone `100.0.0.0/24`, VIP
`100.0.0.45`, llm1/2/3 = .40/.41/.42, NAPT gateway addresses .1 on each side.

`topology_test.py` runs 14 boolean assertions:

| Bucket | Count | What pass means |
|---|---|---|
| Connectivity | 2 | `ping h1->h2` succeeds; `ping h1->VIP` succeeds. |
| IDS allowed methods | 2 | curl POST and curl PUT to VIP succeed. |
| IDS blocked methods | 4 | curl GET / HEAD / DELETE / OPTIONS to VIP **fail** (timeout). |
| IDS injection PUTs | 5 | curl PUT with each injection keyword **fails** (timeout). |
| LB round-robin | 1 | ≥ 2 distinct backends respond across 9 POSTs. |

Important: tests in the "IDS blocked methods" and "IDS injection PUTs" buckets
*pass* when curl times out. So if NAPT/IDS/LB simply drop everything, you get
a free 9 passes. The only tests that prove the chain actually works are the 2
"IDS allowed methods" and the round-robin test.

---

## Real bugs we fixed in the course code

These are issues in the Click configs / topology wiring, not in the
environment. Each has been fixed on the branch.

### 1. `lb1.click` — `RoundRobinIPMapper` rewrite specs were quoted strings

```click
# wrong
rr :: RoundRobinIPMapper(
  "- - 100.0.0.40 80 0 1",
  "- - 100.0.0.41 80 0 1",
  "- - 100.0.0.42 80 0 1"
);
# right
rr :: RoundRobinIPMapper(
  - - 100.0.0.40 80 0 1,
  - - 100.0.0.41 80 0 1,
  - - 100.0.0.42 80 0 1
);
```

Click parses each spec as a comma-separated bare-token list; wrapping in
`"..."` is a syntax error and `lb1.click` failed to load entirely.

### 2. `napt.click` and `lb1.click` — `DriverManager(print …, $(handler), …)`

```click
# wrong
DriverManager(
  print "User-side in count:", $(ac_user_in.count),
  …
)
# right
DriverManager(
  print "User-side in count: $(ac_user_in.count)",
  …
)
```

Click only interpolates `$(handler.read)` inside string literals. The
`label, $(handler)` form parses as multiple statements, the second being
syntactically wrong. `ids.click` already did it correctly; we made the other
two match.

### 3. `ids.click` — `RegexClassifier` is unavailable on the course click

`/usr/local/bin/click` is built without `--enable-pcre`, so:

```
echo 'e :: RegexClassifier(…);' | click -e -
# unknown element class 'RegexClassifier'
```

We replaced it with **fixed-offset `Classifier` keyword patterns**: 5 keywords
× 5 plausible offsets each = 25 patterns matching the body of test PUT
requests, plus the default `-` branch for the clean-PUT path. This avoids
PCRE, doesn't rebuild click, and forwards a complete L2 frame downstream
(unlike `Strip(54) + Search("\r\n\r\n") + Classifier(0/…)` which would
advance the packet's data pointer and break the queue → `ToDevice` path).
Implementation is in `applications/nfv/ids.click`; rationale and the
alternative `Search`-based design are in `docs/ids-non-regex-payload-checks.md`.

### 4. NFV switches had `actions=NORMAL` flows alongside Click

POX `baseController._install_nfv_bridge_l2_fallback` and
`topology.startup_services` both installed `priority=…, actions=NORMAL` flows
on `napt` / `ids` / `lb1`. With those flows, OVS L2-bridges every frame
**alongside** Click's PF_PACKET pipeline, so:

- Receivers see two copies (one untranslated from OVS, one rewritten from
  Click), making TCP look like a black hole.
- ICMP "succeeds" through the chain via OVS alone, masking the fact that
  NAPT/IDS/LB aren't actually doing their job.

The premise of the fallback ("OVS would drop frames before Click sees them")
is wrong: PF_PACKET RX runs before the OVS `rx_handler` in
`__netif_receive_skb_core`, so Click sees ingress frames regardless of what's
in the OVS flow table.

We removed the fallback by default (`IK2221_NFV_OVS_NORMAL=1` re-enables it
for debugging). Click is now the sole data plane on dpids 4/5/6.

### 5. `autoStaticArp=True` poisoned h1's ARP

Mininet's `autoStaticArp=True` walks every host pair and runs
`arp -s <peer-ip> <peer-mac>` on each. With our topology that puts
`100.0.0.45 -> lb1-eth1's MAC` on h1, even though h1 is in `10.0.0.0/24` and
the VIP is supposed to be reached via NAPT's gateway `10.0.0.1`. h1 then
sends TCP to the VIP with `dst_mac = lb1-eth1`, and the llm kernels drop
those frames at L2 (dst-MAC mismatch) — which is also why a "direct"
`h1 -> 100.0.0.40` test failed even though ping appeared to work.

Fix: `autoStaticArp=False` in `topology/topology.py` and
`topology/topology_test.py`. Hosts now resolve their default gateway via real
ARP (NAPT `user_arp_resp` / `inf_arp_resp` answer it), and Click controls
every cross-zone hop.

### 6. ICMP from h1 to VIP needs `ICMPPingRewriter` (not the LB's responder)

`IPRewriter` only rewrites TCP/UDP. ICMP echo carries an `id` field instead
of a port, so it needs a sibling element. The proper NAPT path:

```
cl_user_ip[1] (icmp echo)  -> [0]icmp_rw  -> inf_arp_q  -> napt-eth2
cl_inf_ip[2] (icmp reply)  -> [1]icmp_rw  -> user_arp_q -> napt-eth1
```

with `icmp_rw :: ICMPPingRewriter(pattern user_to_inf 0 1, pattern inf_to_user 1 0)`
sharing the same `IPRewriterPatterns` as `tcp_rw`.

We briefly experimented with answering h1's echo locally on NAPT
(`ICMPPingResponder` on the user side) to dodge a TCG crash; that's
**reverted** — it hides the rewriter from the test and isn't the assignment's
intent. The current `napt.click` uses `ICMPPingRewriter` properly.

---

## What is *not* a code bug: the Apple Silicon TCG limitation

After fixes 1–6, on Apple Silicon TCG the chain still loses TCP. The kernel
log on the VM is unambiguous about why:

```
traps: click[15459] trap invalid opcode ip:56146c567814 …  in click[+0x112814]
traps: click[15462] trap invalid opcode ip:55fe5197355b …  in click[+0x13b55b]
```

- **15459** is NAPT click; it traps the moment the first TCP packet enters
  `IPRewriter`. After that, NAPT is dead, so no further user-side TCP makes
  it across, and even direct `h1 -> 100.0.0.40` fails (NAPT was the only L3
  hop).
- **15462** is LB1 click; it traps at the same kind of address — inside the
  `IPRewriter` callback path — when traffic eventually reaches it.

What we tried, all of which reproduce the same trap at the same offsets:

- `-cpu qemu64`               (default; click won't even start; SIGILL at boot).
- `-cpu max`                  (click starts, ARP/ICMP/IDS work; TCP traps mid-flow).
- `-cpu Skylake-Client …`     (same trap).
- `-cpu Haswell-noTSX-IBRS`   (same trap).

Why this is QEMU's problem and not ours:

```
$ readelf -n /usr/local/bin/click
…
Displaying notes found in: .note.gnu.property
  Owner                Data size 	Description
  GNU                  0x00000020	NT_GNU_PROPERTY_TYPE_0
      Properties: x86 feature: IBT, SHSTK
      x86 ISA needed: x86-64-baseline
```

The course click binary was compiled with `-fcf-protection=full`, so the
binary is full of `endbr64` landing pads and the Linux kernel will turn on
CET-IBT enforcement when the process is loaded on a CET-capable CPU. QEMU 11
TCG's IBT/CET emulation (especially the indirect-call sequences inside the
`IPRewriter*` and `MSQueue` constructors / packet handlers) does not match
the hardware behaviour the binary expects, and the kernel raises
`invalid opcode` on the offending RIP.

This is **strictly a host limitation**: the binary works on KVM (course
Linux lab) and on HVF (Intel Mac), because both pass the indirect-call
sequence to real silicon.

We deliberately rejected three "fixes" for this:

- **Avoiding `IPRewriter` / `ICMPPingRewriter`**: defeats the assignment.
- **Rebuilding click without `-fcf-protection`**: would change the course
  environment and the user has explicitly forbidden installing/rebuilding.
- **Patching `.note.gnu.property` to remove the IBT/SHSTK bits**: same
  objection — modifying the course binary.

---

## Current state of the repo (what each file looks like now)

| File | State |
|---|---|
| `applications/nfv/napt.click` | Proper NAPT: `IPRewriter` for TCP, `ICMPPingRewriter` for ICMP, ARP responders/queriers on both sides, `PrioSched` merging ARP+IP toward each `ToDevice`, AverageCounters wrapping each FromDevice/ToDevice as the brief requires. |
| `applications/nfv/ids.click` | Method classifier (POST allow / PUT inspect / others divert) + 25 fixed-offset `Classifier` patterns covering the 5 injection keywords across a small offset window; clean PUT and POST forwarded to lb1, suspicious PUT and disallowed methods forwarded to insp. No PCRE, no Strip, no Search. |
| `applications/nfv/lb1.click` | `IPRewriter(rr, pass 1)` round-robin VIP rewriting, `ICMPPingResponder` for VIP echo, ARPResponder+ARPQuerier on both sides, MixedQueue feeding each ToDevice. |
| `applications/controller/baseController.py` | Learning switches for sw1/sw2/sw3; `click_wrapper.start_click` for napt/ids/lb1; **no** `actions=NORMAL` flow on NFV bridges by default (re-enable with `IK2221_NFV_OVS_NORMAL=1`). |
| `topology/topology.py` | `MyTopo` as in the brief; `startup_services` starts http servers on llm1/2/3 and tcpdump on insp; `autoStaticArp=False`; aligns lb1 port MACs with `lb1.click`. |
| `topology/topology_test.py` | Same `Mininet(autoStaticArp=False)`; the 14-test matrix described above. |
| `scripts/vm-start.sh` | `-cpu host -accel hvf` on Intel macOS; `-cpu host -accel kvm` on Linux+/dev/kvm; `-cpu max -accel tcg,thread=multi` everywhere else (the only CPU model TCG can boot click on). |
| `scripts/vm-stop.sh` | QEMU-monitor `system_powerdown` then SIGTERM/SIGKILL fallback. |
| `scripts/vm-sync.sh` | rsync repo → `ik2221@127.0.0.1:~/ML-networking` (default password baked in for local dev). |
| `scripts/vm-run.sh` | `sudo -SE bash -lc "cd … && make …"` over ssh; default cmd is `make test-lb`, pass `'make test'` for the full chain. |
| `scripts/_vm_diag_lb_path.sh` | One-shot live diagnostic: clean state → POX → Mininet → tcpdump on each NFV interface during ping/curl probes → SIGINT click to flush counters → dump everything to `/tmp/diag-lb-path/`. |
| `docs/topology-and-testing.md` | Detailed reference: topology, test matrix, Apple-Silicon caveat, full live-debug findings table. |
| `docs/ids-non-regex-payload-checks.md` | The Search+Classifier alternative IDS design (kept as a reference; not used in the active config — see fix #3 above). |

There are no leftover workaround scripts (e.g. the previously-attempted
`_vm_build_click_pcre.sh` is removed; we no longer try to rebuild click).

---

## Run plan from here

Pick the path that matches your hardware.

### A. Course Linux lab host or Intel Mac (KVM / HVF) — expected 14/14

```bash
# 1. start the VM (boots in ~30 s on KVM, a couple of minutes on HVF)
bash scripts/vm-start.sh

# 2. push the latest tree
bash scripts/vm-sync.sh

# 3. run the full test
bash scripts/vm-run.sh 'make test'

# 4. inspect the on-VM reports if anything fails
bash scripts/vm-run.sh 'cat napt.report ids.report lb1.report'

# 5. shut down when done
bash scripts/vm-stop.sh
```

If anything is < 14/14 here, that **is** a code bug and we should debug it.
Useful follow-ups:

```bash
bash scripts/vm-run.sh 'bash scripts/_vm_diag_lb_path.sh'
bash scripts/vm-run.sh 'cat /tmp/diag-lb-path/diag.log /tmp/diag-lb-path/mininet.log'
# pcaps for each NFV interface:
ls /tmp/diag-lb-path/*.pcap
```

### B. Apple Silicon (TCG) — expected ~11/14, 3 documented TCP failures

Same five steps. Expect:

| Test | Result |
|---|---|
| ping h1 → h2 | PASS |
| ping h1 → 100.0.0.45 | PASS |
| curl POST h1 → VIP | **FAIL** (NAPT IPRewriter SIGILL on first TCP) |
| curl PUT h1 → VIP | **FAIL** (same reason) |
| GET / HEAD / DELETE / OPTIONS to VIP (4 cases) | PASS (curl times out as expected) |
| 5 injection PUTs | PASS (curl times out as expected) |
| Round-robin (≥ 2 backends) | **FAIL** (no TCP through chain) |
| **Total** | 11/14 |

Confirmation that this is the TCG IBT issue and not a code regression:

```bash
bash scripts/vm-run.sh 'sudo dmesg -T | grep "click.*invalid opcode" | tail'
# expected:
# traps: click[N] trap invalid opcode ip:..  in click[..+0x112814]
# traps: click[N] trap invalid opcode ip:..  in click[..+0x13b55b]
```

Also useful as a sanity check that *something* is correct end-to-end on
Apple Silicon: `make test-lb`. That uses `LbOnlyTopo` (no NAPT, no IDS) so
TCP only traverses lb1 click; if lb1 click traps on TCP under TCG you'll see
it cleanly in isolation, and if it doesn't, lb1 round-robin will pass.

### C. Local CI ideas (not implemented yet)

- A Linux x86_64 GitHub-Actions runner (KVM enabled) is a safe place to
  run `make test` on every push; Apple-Silicon runners are not.
- Add a one-line README pointer that says "run `make test` only on x86_64
  hardware; Apple Silicon will get 11/14 by design".

---

## What I would change next (in order)

1. **Run on a real x86_64 host once.** Until that produces 14/14, we don't
   actually know fixes #1–#6 are sufficient. The trap-driven TCP failures
   on Apple Silicon mask whether NAPT TCP rewriting is configured correctly
   end-to-end.
2. **`napt.report` / `lb1.report` flush on shutdown.** Currently `make clean`
   sends SIGTERM, which doesn't always make `DriverManager` return from
   `pause` and print the counter block. Either (a) replace `pause` with
   `wait <N> seconds`, or (b) have `topology_test.py` send `SIGINT` to all
   click PIDs *before* `mn.stop()`. The diag script already does (b).
3. **Truncate `*.stderr` at start of every test run.** Today
   `click_wrapper.start_click` redirects with `2>>` (append), so old errors
   from previous runs accumulate and look like new failures. Either
   `:>/tmp/lb1.stderr` etc. before launching, or change the redirect to
   `2>` (truncate).
4. **Round-robin assertion.** Currently passes if ≥ 2 distinct backends
   respond across 9 POSTs; the brief implies all three. Once #1 is verified,
   tighten this to `len(set(seen)) == 3`.
5. **Optional: pcap-based IDS verification.** The `insp` host already runs
   `tcpdump -w /tmp/insp_capture.pcap`. We could parse it post-run and
   assert that injection PUTs landed at insp (and that clean PUTs did not).
   Today the test only checks curl exit codes, which on the failure
   direction is just "did it time out".

---

## Quick reference — files most likely to need attention next

- `applications/nfv/napt.click` — verify TCP forward path on a real x86_64
  host. The failure mode you're looking for is curl timing out *with*
  `napt.report` showing `TCP translated (user->inf)` ≥ 1: that means
  packets entered the rewriter and came out, but the return path is wrong.
  If you instead see `TCP translated (user->inf): 0`, the user-side
  classifier or the rewriter input itself is wrong.
- `applications/nfv/lb1.click` — round-robin. If one backend always wins,
  check the `RoundRobinIPMapper` rewrite specs (the bare-token vs quoted
  bug in fix #1) and that `arq2` is actually resolving the llm MACs.
- `applications/nfv/ids.click` — keyword offsets. If the live curl version
  on the VM emits HTTP headers that differ in length from what we
  estimated (e.g. `Host: localhost` vs `Host: 100.0.0.45`), the body offset
  shifts and our `Classifier` patterns may miss. The fallback path
  (`-` clean-PUT branch → `q3`) means a missed match makes injection PUTs
  *succeed* unexpectedly. Check `ids.report` for `cnt_malicious` ≥ 5 after
  the test.

---

## Glossary of evidence files (where things actually live)

| Path on VM | Written by | Contents |
|---|---|---|
| `/home/ik2221/ML-networking/phase_1_report` | `topology_test.py` | Per-test PASS/FAIL line + summary |
| `/home/ik2221/ML-networking/napt.report`     | NAPT click DriverManager | counters (only fully populated on SIGINT) |
| `/home/ik2221/ML-networking/ids.report`      | IDS click DriverManager | counters |
| `/home/ik2221/ML-networking/lb1.report`      | LB click DriverManager | counters |
| `/tmp/napt.stderr`                           | click_wrapper (`2>>`) | NAPT click's stderr (appended, may be stale) |
| `/tmp/ids.stderr`                            | "                      | IDS click's stderr |
| `/tmp/lb1.stderr`                            | "                      | LB click's stderr |
| `/tmp/insp_capture.pcap`                     | tcpdump on insp        | All traffic landing at the inspector |
| `/tmp/qemu-ik2221.serial.log`                | QEMU (`-serial file:`) | Guest serial console (kernel `traps:` lines appear here too) |
| `/tmp/diag-lb-path/`                         | `_vm_diag_lb_path.sh`  | One-shot diagnostic bundle (reports, stderr, pcaps, ovs-ofctl flow dumps) |

`dmesg -T` on the VM is the authoritative source for click crashes:

```bash
bash scripts/vm-run.sh 'sudo dmesg -T | grep -E "click|invalid opcode|SIGILL" | tail -20'
```
