#!/usr/bin/env bash
# Run POX in the background, execute LB-only Mininet tests, then tear down.
# Intended for the IK2221 VM (sudo, /opt/pox, click).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export IK2221_LB_REPORT="${IK2221_LB_REPORT:-$ROOT/lb1.report}"

POXDIR="${POXDIR:-/opt/pox/}"
make clean || true
cp applications/controller/* "${POXDIR}ext/"
cp applications/nfv/*.click "${POXDIR}ext/"

echo "[run_lb_integration_test] starting POX..."
sudo -E bash -c "cd '$ROOT' && export IK2221_LB_REPORT='$IK2221_LB_REPORT' && python3 '${POXDIR%/}/pox.py' baseController" &
cleanup() {
  echo "[run_lb_integration_test] stopping POX / Click / Mininet"
  sudo pkill -f 'pox.py baseController' || true
  sudo killall -SIGTERM click 2>/dev/null || true
  sudo mn -c 2>/dev/null || true
}
trap cleanup EXIT
# Slow QEMU/TCG or first Click/OVS bring-up may need more than a few seconds.
WARMUP_SEC="${IK2221_POX_WARMUP_SEC:-20}"
echo "[run_lb_integration_test] waiting ${WARMUP_SEC}s for POX/Click/OVS..."
sleep "$WARMUP_SEC"

echo "[run_lb_integration_test] running topology_test_lb.py..."
set +e
sudo -E env IK2221_LB_REPORT="$IK2221_LB_REPORT" PYTHONPATH="$ROOT" \
  python3 "$ROOT/topology/topology_test_lb.py"
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
  echo "[run_lb_integration_test] tests failed (exit $rc); last lines of Click stderr:"
  sudo tail -40 /tmp/lb1.stderr 2>/dev/null || true
fi
exit "$rc"
