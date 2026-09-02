#!/bin/bash
# Stage KernelSU-Next daemon into the Waydroid container's /data.
#
# Container /data is bind-mounted from /home/meowl/.local/share/waydroid/data
# on the host, so we write directly there (no chroot needed).
#
# Idempotent: safe to run every boot.

set -euo pipefail

DATA_DIR="${KERNELSU_DATA_DIR:-/home/meowl/.local/share/waydroid/data}"
KSU_BIN="${KERNELSU_KSU_BIN:-/usr/local/lib/kernelsu/ksud}"

KSUD="$DATA_DIR/adb/ksud"
BINDIR="$DATA_DIR/adb/ksu/bin"

echo "[*] staging ksud for container /data ($DATA_DIR)"

if [ ! -f "$KSU_BIN" ]; then
  echo "[!] source ksud not found at $KSU_BIN; skipping stage" >&2
  exit 1
fi

mkdir -p "$DATA_DIR/adb"
mkdir -p "$BINDIR"

install -Dm755 "$KSU_BIN" "$KSUD" 2>/dev/null || { echo "[!] stage failed (is container /data writable?)" >&2; exit 1; }

# busybox (asset) not embedded; copy the checked-in one if present next to ksud
if [ -f "$(dirname "$KSU_BIN")/busybox" ]; then
  install -Dm755 "$(dirname "$KSU_BIN")/busybox" "$BINDIR/busybox"
fi

# ksud symlink + resetprop link, mirroring ksud install() (assets.rs / defs.rs)
ln -sfn /data/adb/ksud "$BINDIR/ksud"
ln -sfn /data/adb/ksud "$BINDIR/resetprop"

echo "[*] staged:"
ls -la "$DATA_DIR/adb" "$BINDIR"
echo "[*] done"