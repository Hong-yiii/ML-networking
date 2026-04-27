#!/usr/bin/env bash
# Run remote command read from stdin on the VM: stdin → ssh ... bash -lc <cmd>.
# Usage: printf '%s' "cd ~/x && make" | scripts/vm-ssh-exec.sh 2222 ik2221@127.0.0.1
set -euo pipefail
PORT="${1:?port}"
USERHOST="${2:?user@host}"
CMD="$(cat)"
exec ssh -tt -p "$PORT" -o StrictHostKeyChecking=accept-new "$USERHOST" \
  "bash -lc $(printf '%q' "$CMD")"
