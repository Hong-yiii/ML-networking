# POX controller and Click launcher

The **control plane** is POX. It installs **learning switches** on normal fabric DPIDs and **starts Click** on the three NFV “switches.”

## Files

- `applications/controller/baseController.py` — OpenFlow `ConnectionUp` handling.
- `applications/controller/click_wrapper.py` — `sudo click …` with stdout/stderr redirection.

## DPID routing (`baseController.py`)

On each switch connection:

| DPID | Behavior |
|------|----------|
| `≤ 3` | `forwarding.l2_learning.LearningSwitch(connection, False)` for `sw1`–`sw3`. |
| `4` | Start Click **`napt.click`** (`/opt/pox/ext/napt.click`). |
| `5` | Wait up to ~20s for `/sys/class/net/ids-eth1`, then start **`ids.click`**. |
| `6` | Start **`lb1.click`**. |
| other | Log error (`Unknown device`). |

**Invariant:** Mininet must assign DPIDs **4 / 5 / 6** to `napt`, `ids`, `lb1` respectively, or the wrong handler runs.

## Environment variables (report and stderr paths)

Passed as the **stdout** and **stderr** paths to `click_wrapper.start_click`:

| NFV | Report env (default) | Stderr env (default) |
|-----|----------------------|----------------------|
| NAPT | `IK2221_NAPT_REPORT` → `/tmp/napt.report` | `IK2221_NAPT_STDERR` → `/tmp/napt.stderr` |
| IDS | `IK2221_IDS_REPORT` → `/tmp/ids.report` | `IK2221_IDS_STDERR` → `/tmp/ids.stderr` |
| LB | `IK2221_LB_REPORT` → `/tmp/lb1.report` | `IK2221_LB_STDERR` → `/tmp/lb1.stderr` |

`make test` sets the report variables under the **repository root** so grading artifacts land next to `phase_1_report`.

## `click_wrapper.py` behavior

- Launches: `sudo click <config> <params> >stdout 2>>stderr &` (stdout truncate, stderr append).
- Tracks shell `Popen` PIDs in `click_pids`; teardown helpers use **`killall -SIGTERM click`** rather than per-PID cleanup.
- `handle_kill` / `killall_click` exist here; **`baseController.py` does not register signal handlers** for them in-repo—production teardown is typically `make clean` / killing POX.

## Deployment assumption

Click config paths are **hard-coded** to `/opt/pox/ext/*.click`. `make app` / `make test` copy `applications/controller/*` and `applications/nfv/*.click` into `$(poxdir)ext/` (default `poxdir=/opt/pox/`).

## Why this split matches NFV thinking

- **Fabric** (`sw1`–`sw3`): classic OpenFlow L2 learning—**general-purpose forwarding**.
- **NFV nodes** (`napt`, `ids`, `lb1`): **programmable packet processing in Click** on the switch namespace’s Linux interfaces, not a flow program expressed purely in OpenFlow tables.

## Key files

- `applications/controller/baseController.py`
- `applications/controller/click_wrapper.py`

See also: [topology-and-testing.md](topology-and-testing.md) (DPID alignment), [build-test-and-vm.md](build-test-and-vm.md), and each [nfv-*.md](README.md).
