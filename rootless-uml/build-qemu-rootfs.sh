#!/bin/bash
# build-qemu-rootfs.sh — build ~/uml-smoke/qemu-rootfs.img for QEMU
# cross-checks, rootlessly (mkfs.ext4 -d, no mounts).
#
# Contents = rootfs-xfs (deployed guest scripts included) + the CURRENT
# xfstests-built at /opt/xfstests. Always run deploy.sh first so qemu-init
# and friends are current. Rebuild whenever xfstests-built or the rootfs
# changes — a stale image silently cross-checks with an old harness (the
# July 2026 image carried an April xfstests; cost us a bogus crosscheck).
set -euo pipefail
BASE="${BASE:-$HOME/uml-smoke}"
ROOTFS="${ROOTFS:-$BASE/rootfs-xfs}"
XT="$BASE/xfstests-built"
IMG="$BASE/qemu-rootfs.img"
SIZE="${SIZE:-6G}"
STAGE="$BASE/qemu-stage"
log(){ echo "[qemu-rootfs] $*"; }

[ -d "$ROOTFS" ] || { log "no rootfs at $ROOTFS"; exit 1; }
[ -f "$XT/common/rc" ] || { log "no xfstests-built at $XT"; exit 1; }
[ -x "$ROOTFS/qemu-init" ] || { log "qemu-init not deployed — run deploy.sh first"; exit 1; }

log "staging (hardlinks)..."
rm -rf "$STAGE"
cp -al "$ROOTFS" "$STAGE"
# never inherit a baked-in xfstests from the rootfs — always the current build
rm -rf "$STAGE/opt/xfstests"
mkdir -p "$STAGE/opt"
cp -al "$XT" "$STAGE/opt/xfstests"

log "mkfs.ext4 -d ($SIZE)..."
rm -f "$IMG"
truncate -s "$SIZE" "$IMG"
mkfs.ext4 -Fq -d "$STAGE" "$IMG"
log "built: $IMG ($(du -h "$IMG" --apparent-size | cut -f1)) with xfstests $(stat -c %y "$XT/common/rc" | cut -d' ' -f1)"
