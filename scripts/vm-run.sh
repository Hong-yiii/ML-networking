#!/usr/bin/env bash
# Run a command on the VM (default: load-balancer integration test).
#
# Usage:
#   export VM_SSH_PASS='...'          # SSH password if not using keys
#   export VM_SUDO_PASS='...'        # optional; defaults to VM_SSH_PASS when that is set
#   bash scripts/vm-run.sh
#   bash scripts/vm-run.sh 'make test'
#   bash scripts/vm-run.sh 'click-check applications/nfv/lb1.click'
#
# Env: VM_SSH_HOST VM_SSH_PORT VM_SSH_USER VM_REMOTE_DIR (same as vm-sync.sh)

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${VM_SSH_HOST:-127.0.0.1}"
PORT="${VM_SSH_PORT:-2222}"
USER="${VM_SSH_USER:-ik2221}"
REMOTE_DIR="${VM_REMOTE_DIR:-/home/${USER}/ML-networking}"
PASS="${VM_SSH_PASS:-}"
SUDO_PASS="${VM_SUDO_PASS:-}"
if [[ -z "$SUDO_PASS" && -n "$PASS" ]]; then
  SUDO_PASS="$PASS"
fi

wrap_sudo_bash_lc() {
  local inner="$1"
  if [[ -n "$SUDO_PASS" ]]; then
    printf 'echo %q | sudo -SE -p '\'''\'' bash -lc %q' "$SUDO_PASS" "$inner"
  else
    printf '%s' "$inner"
  fi
}

if [[ $# -gt 0 ]]; then
  REMOTE_CMD="$*"
else
  INNER="cd ${REMOTE_DIR} && export IK2221_LB_REPORT=\"${REMOTE_DIR}/lb1.report\" && make test-lb"
  REMOTE_CMD="$(wrap_sudo_bash_lc "$INNER")"
fi

run_pipe_ssh() {
  printf '%s' "$REMOTE_CMD" | "$ROOT/scripts/vm-ssh-exec.sh" "$PORT" "${USER}@${HOST}"
}

run_pipe_ssh_expect() {
  local tmp
  tmp="$(mktemp)"
  printf '%s' "$REMOTE_CMD" >"$tmp"
  expect <<EXPECTEOF
set timeout 3600
spawn bash -c "cat $(printf '%q' "$tmp") | $(printf '%q' "$ROOT/scripts/vm-ssh-exec.sh") $(printf '%q' "$PORT") $(printf '%q' "${USER}@${HOST}")"
expect {
  -re "(?i)password:" { send "$PASS\r"; exp_continue }
  eof
}
EXPECTEOF
  rm -f "$tmp"
}

if ssh -o BatchMode=yes -o ConnectTimeout=3 -p "$PORT" "${USER}@${HOST}" true 2>/dev/null; then
  run_pipe_ssh
elif [[ -n "$PASS" ]]; then
  run_pipe_ssh_expect
else
  echo "SSH needs a key or VM_SSH_PASS." >&2
  exit 1
fi
