#!/usr/bin/env bash
# Boot the IK2221 course VM (ik2221.qcow2) under QEMU on macOS / Linux.
#
# Forwards host TCP 2222 -> guest 22 so scripts/vm-sync.sh and scripts/vm-run.sh
# work against the defaults (VM_SSH_HOST=127.0.0.1 VM_SSH_PORT=2222).
#
# Headless: serial console -> /tmp/qemu-ik2221.serial.log
# QEMU monitor over UNIX socket: /tmp/qemu-ik2221.mon (use `socat - unix:...` to attach).
# QEMU PID file: /tmp/qemu-ik2221.pid
#
# Stop with:  scripts/vm-stop.sh   (or `kill $(cat /tmp/qemu-ik2221.pid)`)

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMG="${VM_IMG:-$ROOT/ik2221.qcow2}"
RAM="${VM_RAM:-4096}"
CORES="${VM_CORES:-4}"
HOST_PORT="${VM_SSH_PORT:-2222}"
PIDFILE=/tmp/qemu-ik2221.pid
SERIAL=/tmp/qemu-ik2221.serial.log
MON=/tmp/qemu-ik2221.mon

if [[ ! -f "$IMG" ]]; then
  echo "[vm-start] missing image: $IMG" >&2
  exit 1
fi

if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  echo "[vm-start] VM already running (pid $(cat "$PIDFILE")). Serial log: $SERIAL"
  exit 0
fi

ACCEL=""
CPU_MODEL=""
case "$(uname -sm)" in
  "Darwin x86_64")
    ACCEL="-accel hvf"
    CPU_MODEL="-cpu host"
    ;;
  "Darwin arm64")
    # Apple Silicon: HVF can only accelerate aarch64 guests, not x86.
    # qemu-system-x86_64 falls back to TCG (slow). The course Click binary in
    # /usr/local/bin/click is built with -march=native + -fcf-protection=full
    # (CET-IBT properties in .note.gnu.property), so under any TCG CPU model
    # NAPT / LB1 hit `invalid opcode` (kernel: `traps: click[..] trap invalid
    # opcode ...`) on the first TCP packet that goes through IPRewriter. ICMP
    # via ICMPPingRewriter trips the same fault. This is a TCG limitation;
    # the course's Intel/Linux lab hosts (KVM / HVF) run the code as-is.
    # We still set `-cpu max` so click can at least START up (`-cpu qemu64`
    # SIGILLs at process spawn). Under TCG you'll get:
    #   - ping h1 -> h2          : pass
    #   - ping h1 -> 100.0.0.45  : pass (LB1 click usually starts; if it
    #                              traps, see docs/topology-and-testing.md)
    #   - curl POST/PUT to VIP   : likely fail (NAPT click traps on TCP)
    # Run the test on a real x86_64 host (KVM or Intel-Mac HVF) for a clean
    # 14/14.
    ACCEL="-accel tcg,thread=multi"
    CPU_MODEL="-cpu max"
    echo "[vm-start] WARNING: arm64 host running x86_64 guest -> TCG only (no HVF)."
    echo "[vm-start] Using -cpu max so click can start (SIGILLs on -cpu qemu64)."
    echo "[vm-start] TCP NAPT path may still SIGILL under TCG; expected to work on KVM/HVF."
    echo "[vm-start] Boot will take several minutes; tests will be markedly slower."
    ;;
  "Linux"*)
    if [[ -e /dev/kvm ]]; then
      ACCEL="-accel kvm"
      CPU_MODEL="-cpu host"
    else
      ACCEL="-accel tcg,thread=multi"
      CPU_MODEL="-cpu max"
    fi
    ;;
esac

echo "[vm-start] booting $IMG (RAM=${RAM}M, cores=${CORES}, ssh -> 127.0.0.1:${HOST_PORT})"
echo "[vm-start] serial console -> $SERIAL"

: >"$SERIAL"
rm -f "$MON"

qemu-system-x86_64 \
  $ACCEL \
  $CPU_MODEL \
  -m "$RAM" -smp "$CORES" \
  -drive "file=${IMG},if=virtio,format=qcow2,cache=writeback" \
  -netdev "user,id=n0,hostfwd=tcp::${HOST_PORT}-:22" \
  -device virtio-net-pci,netdev=n0 \
  -display none \
  -serial "file:${SERIAL}" \
  -monitor "unix:${MON},server,nowait" \
  -pidfile "$PIDFILE" \
  -daemonize

echo "[vm-start] qemu pid $(cat "$PIDFILE")"
echo "[vm-start] tail -f $SERIAL    # to watch boot"
echo "[vm-start] ssh -p ${HOST_PORT} ik2221@127.0.0.1   # once SSH is up"
