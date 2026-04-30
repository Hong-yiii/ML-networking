#!/usr/bin/env bash
# Push this repo to the IK2221 QEMU VM over SSH (rsync).
# Usage:
#   export VM_SSH_PASS='your-password'   # or use SSH keys and skip this
#   bash scripts/vm-sync.sh
#
# Optional env:
#   VM_SSH_HOST (default 127.0.0.1)  VM_SSH_PORT (default 2222)
#   VM_SSH_USER (default ik2221)    VM_REMOTE_DIR (default ~/ML-networking)
#
# --delete mirrors deletions; excludes qcow2 disk images and VCS noise from transfer payload.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${VM_SSH_HOST:-127.0.0.1}"
PORT="${VM_SSH_PORT:-2222}"
USER="${VM_SSH_USER:-ik2221}"
REMOTE_DIR="${VM_REMOTE_DIR:-/home/${USER}/ML-networking}"
PASS="${VM_SSH_PASS:-}"

rsync_cmd=(
  rsync -avz --delete
  --exclude=ik2221.qcow2
  '--exclude=*.qcow2'
  --exclude=.git
  --exclude=.cursor
  --exclude=__pycache__
  -e "ssh -p $PORT -o StrictHostKeyChecking=accept-new"
  "$ROOT/"
  "${USER}@${HOST}:${REMOTE_DIR}/"
)

if ssh -o BatchMode=yes -o ConnectTimeout=3 -p "$PORT" "${USER}@${HOST}" true 2>/dev/null; then
  echo "[vm-sync] SSH key auth OK; rsync without password."
  "${rsync_cmd[@]}"
elif [[ -n "$PASS" ]]; then
  echo "[vm-sync] Using password from VM_SSH_PASS."
  expect <<EXPECTEOF
set timeout 1800
spawn rsync -avz --delete --exclude=ik2221.qcow2 --exclude=\*.qcow2 --exclude=.git --exclude=.cursor --exclude=__pycache__ -e "ssh -p $PORT -o StrictHostKeyChecking=accept-new" "$ROOT/" ${USER}@${HOST}:${REMOTE_DIR}/
expect {
  -re "(?i)password:" { send "$PASS\r"; exp_continue }
  eof
}
EXPECTEOF
else
  echo "Cannot SSH without password and VM_SSH_PASS is unset." >&2
  echo "Either:  export VM_SSH_PASS='...' && bash $0" >&2
  echo "Or:      ssh-copy-id -p $PORT ${USER}@${HOST}" >&2
  exit 1
fi

echo "[vm-sync] Done → ${USER}@${HOST}:${REMOTE_DIR}"
