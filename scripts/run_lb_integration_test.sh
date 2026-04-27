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
sleep 5

echo "[run_lb_integration_test] running topology_test_lb.py..."
sudo -E env IK2221_LB_REPORT="$IK2221_LB_REPORT" PYTHONPATH="$ROOT" \
  python3 "$ROOT/topology/topology_test_lb.py"
