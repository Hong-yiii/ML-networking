#!/usr/bin/env bash
# Stop the QEMU IK2221 VM started by scripts/vm-start.sh.
set -euo pipefail
PIDFILE=/tmp/qemu-ik2221.pid
MON=/tmp/qemu-ik2221.mon

if [[ ! -f "$PIDFILE" ]]; then
  echo "[vm-stop] no pidfile $PIDFILE; nothing to do."
  exit 0
fi

PID="$(cat "$PIDFILE")"
if ! kill -0 "$PID" 2>/dev/null; then
  echo "[vm-stop] pid $PID not running; cleaning pidfile."
  rm -f "$PIDFILE" "$MON"
  exit 0
fi

if [[ -S "$MON" ]] && command -v socat >/dev/null 2>&1; then
  echo "[vm-stop] sending system_powerdown via QEMU monitor"
  echo "system_powerdown" | socat - "unix:${MON}" >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do
    kill -0 "$PID" 2>/dev/null || break
    sleep 1
  done
fi

if kill -0 "$PID" 2>/dev/null; then
  echo "[vm-stop] still alive; SIGTERM pid $PID"
  kill "$PID" 2>/dev/null || true
  for _ in $(seq 1 10); do
    kill -0 "$PID" 2>/dev/null || break
    sleep 1
  done
fi
if kill -0 "$PID" 2>/dev/null; then
  echo "[vm-stop] forcing SIGKILL"
  kill -9 "$PID" 2>/dev/null || true
fi

rm -f "$PIDFILE" "$MON"
echo "[vm-stop] done."
