#!/bin/bash
# install-btrfs-progs.sh — install the latest btrfs-progs into the rootfs.
#
# Uses the upstream prebuilt STATIC multi-call binary (btrfs.box.static) from the
# kdave/btrfs-progs GitHub release — no building, no lib deps, runs on any kernel.
# The box dispatches on argv[0], so we symlink each tool name to it. This keeps
# userspace btrfs-progs current with the btrfs dev kernel we test against.
#
# Usage: BASE=~/uml-smoke [VER=v7.0] ./install-btrfs-progs.sh
set -euo pipefail
BASE="${BASE:-$HOME/uml-smoke}"
R="$BASE/rootfs-xfs"
VER="${VER:-$(curl -s https://api.github.com/repos/kdave/btrfs-progs/releases/latest | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')}"
URL="https://github.com/kdave/btrfs-progs/releases/download/${VER}/btrfs.box.static"

echo "Installing btrfs-progs ${VER} (static box) into $R ..."
wget -q "$URL" -O "$R/usr/sbin/btrfs.box"
chmod +x "$R/usr/sbin/btrfs.box"

# All tool names the box dispatches on (superset; harmless if unused by a test).
# NOTE: btrfs-corrupt-block is NOT in the box (symlinking it silently runs plain
# `btrfs` -> "Unknown global option"). It must be a real binary built from source.
TOOLS="mkfs.btrfs btrfs btrfs-image btrfstune fsck.btrfs btrfsck btrfs-map-logical \
btrfs-select-super btrfs-find-root btrfs-convert btrfs-zero-log"
cd "$R"
for t in $TOOLS; do
  for d in usr/bin usr/sbin bin sbin; do
    [ -e "$d/$t" ] || [ -L "$d/$t" ] && ln -sf btrfs.box "$d/$t"
  done
  [ -e "usr/sbin/$t" ] || ln -sf btrfs.box "usr/sbin/$t"
done
echo -n "installed: "; ./usr/sbin/mkfs.btrfs --version | head -1
