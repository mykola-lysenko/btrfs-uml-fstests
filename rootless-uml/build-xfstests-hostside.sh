#!/bin/bash
# build-xfstests-hostside.sh — build xfstests on the HOST using the assembled
# rootfs toolchain, via an unprivileged user namespace. Rootless.
#
# Why: building inside UML is very slow (single slow CPU, ~30 min). The rootfs
# toolchain hardcodes /usr paths, so we bind-mount rootfs-xfs/usr over /usr inside
# an unprivileged userns and build natively with all the host's cores (~12s).
# The resulting x86-64 binaries run fine inside the guest (same Ubuntu userspace).
#
# Prereq: unprivileged user namespaces enabled (cat /proc/sys/user/max_user_namespaces > 0).
# Usage: BASE=~/uml-smoke XFSSRC=~/uml-smoke/xfstests-master ./build-xfstests-hostside.sh
set -euo pipefail
BASE="${BASE:-$HOME/uml-smoke}"
XFSSRC="${XFSSRC:-$BASE/xfstests-master}"
R="$BASE/rootfs-xfs"
log(){ echo "[$(date '+%H:%M:%S')] $*"; }

[ -d "$XFSSRC" ] || { echo "xfstests source not found at $XFSSRC"; exit 1; }
rm -rf /tmp/xfsbuild && cp -a "$XFSSRC" /tmp/xfsbuild

log "Building xfstests in userns (bind /usr -> rootfs prefix)..."
unshare --map-root-user --mount bash -c "
  mount --bind '$R/usr' /usr
  export PATH=/usr/bin:/usr/sbin:/bin:/sbin
  cd /tmp/xfsbuild && rm -f configure
  make -j\$(nproc)
"
log "built binaries: $(ls /tmp/xfsbuild/ltp/fsstress /tmp/xfsbuild/src/fsx 2>/dev/null | wc -l)/2"

# btrfs-progs v7.0 compat: xfstests decides whether to add `-f` to mkfs.btrfs by
# grepping `mkfs.btrfs --help` for an indented `-f`; v7.0 prints it at column 0,
# so `-f` is never added and scratch/recreate mkfs fails on an existing fs. Allow
# the option at line start too.
sed -i 's#grep -q "\[\[:space:\]\]-f\[\[:space:\]|,\]"#grep -qE "(^\|[[:space:]])-f[[:space:]|,]"#' \
  /tmp/xfsbuild/common/config

rm -rf "$BASE/xfstests-built" && cp -a /tmp/xfsbuild "$BASE/xfstests-built"
log "persisted to $BASE/xfstests-built (guest restores this to tmpfs)"
