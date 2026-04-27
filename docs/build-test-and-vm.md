# Build, test, and VM workflow

## `Makefile` targets

| Target | What it does |
|--------|----------------|
| **`topo`** | `sudo python ./topology/topology.py` — interactive Mininet + CLI. |
| **`app`** | Copy `applications/controller/*` and `applications/nfv/*.click` to `$(poxdir)ext/`, then `sudo python $(poxdir)pox.py baseController`. Default **`poxdir=/opt/pox/`**; override: `make poxdir=/path/ app`. |
| **`test`** | **Phase 1 automated suite**: `make clean`, copy sources to POX `ext/`, start POX in background with report env vars, `sleep 8`, run `topology/topology_test.py` under `MN_AUTOMATED=1` with `PYTHONPATH=$(CURDIR)`, tee **`phase_1_report`**, then `make clean`. POX’s own stdout/stderr go to **`/tmp/pox_test.stdout`** during this target. |
| **`test-lb`** | `POXDIR="$(poxdir)" bash scripts/run_lb_integration_test.sh` — **LB-only** topology (`topology_test_lb.py`), longer default warmup for slow VMs (`IK2221_POX_WARMUP_SEC`, default 20s in script). |
| **`vm-sync`** | `bash scripts/vm-sync.sh` — rsync repo to the course VM (see script for `VM_*` env). |
| **`vm-test-lb`** | `bash scripts/vm-run.sh` — SSH to VM and run **`make test-lb`** with sudo (password via env if needed). |
| **`clean`** | Remove copied controller/click files from `$(poxdir)ext/`, kill POX, `sudo mn -c`, `sudo killall click`. |

## Artifacts

| Artifact | Produced by |
|----------|-------------|
| `phase_1_report` | **`make test`** (`tee` of `topology_test.py` output). |
| `napt.report`, `ids.report`, `lb1.report` | Click processes; stdout redirected per `IK2221_*_REPORT` in `make test`. |

## `scripts/run_lb_integration_test.sh`

- Repo root discovery, optional **`IK2221_LB_REPORT`**, **`POXDIR`** default `/opt/pox/`.
- `make clean` (best effort), copy into `POXDIR/ext/`, start **POX** in background with `sudo`, register trap to kill POX/Click/`mn -c` on exit.
- Waits **`IK2221_POX_WARMUP_SEC`** (default **20**) then runs `sudo -E … python3 topology/topology_test_lb.py`.

## `scripts/vm-sync.sh`

- **rsync** project to `VM_REMOTE_DIR` on `VM_SSH_USER@VM_SSH_HOST` (default `ik2221@127.0.0.1:2222` → `~/ML-networking`).
- Excludes `.git`, `.cursor`, `__pycache__`, `*.qcow2`, etc.
- Supports SSH keys or **`VM_SSH_PASS`** with `sshpass` when needed.

## `scripts/vm-run.sh`

- SSH to the same VM defaults as `vm-sync.sh`.
- Default remote command: `cd` to synced tree, set **`IK2221_LB_REPORT`**, **`make test-lb`** under `sudo` (optional **`VM_SUDO_PASS`** / **`VM_SSH_PASS`**).
- Any arguments replace the remote command: `bash scripts/vm-run.sh 'make test'`.

## Practical order (course VM)

1. **`make app`** in one terminal (or let **`make test`** start POX).
2. **`make topo`** in another for interactive work; or run **`make test`** once for automation.

For development on the host Mac: **`make vm-sync`** then **`make vm-test-lb`** or SSH in and run **`make test`**.

See also: [README.md](README.md) (doc index), [topology-and-testing.md](topology-and-testing.md), [controller-and-click-wrapper.md](controller-and-click-wrapper.md).
