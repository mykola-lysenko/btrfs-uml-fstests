#!/bin/bash
# build-btrfs-debug-tools.sh — build the btrfs-progs debug tools the static
# btrfs.box does NOT dispatch, and install them into the rootfs. Rootless.
#
# The box dispatches mkfs.btrfs/btrfs/btrfs-image/btrfstune/btrfsck/
# btrfs-find-root/btrfs-convert — but NOT btrfs-corrupt-block,
# btrfs-map-logical, btrfs-select-super (argv0 falls through to plain `btrfs`,
# which prints "Unknown global option: -l" — this silently broke ~8 tests).
#
# Build deps come from a throwaway deb-extracted sysroot (no sudo): -dev
# headers via apt-get download + dpkg-deb -x, runtime .so.N copied from host.
#
# Usage: BASE=~/uml-smoke [VER=v7.0] ./build-btrfs-debug-tools.sh
set -euo pipefail
BASE="${BASE:-$HOME/uml-smoke}"
R="$BASE/rootfs-xfs"
WORK="${WORK:-$BASE/btrfs-progs-build}"
VER="${VER:-$(curl -s https://api.github.com/repos/kdave/btrfs-progs/releases/latest | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')}"
TOOLS="btrfs-corrupt-block btrfs-map-logical btrfs-select-super"
log(){ echo "[$(date '+%H:%M:%S')] $*"; }

mkdir -p "$WORK/sysroot" && cd "$WORK"
SYS="$WORK/sysroot"; L="$SYS/usr/lib/x86_64-linux-gnu"

log "sysroot: dev headers (apt-get download, no root)"
for p in uuid-dev libblkid-dev liblzo2-dev libudev-dev; do
  ls ${p}_*.deb >/dev/null 2>&1 || apt-get download "$p" >/dev/null 2>&1
done
for d in *.deb; do dpkg-deb -x "$d" "$SYS"; done
# -dev packages ship only the .so symlink; the linker needs the real .so.N
cp -a /usr/lib/x86_64-linux-gnu/libblkid.so.1* /usr/lib/x86_64-linux-gnu/libuuid.so.1* \
      /usr/lib/x86_64-linux-gnu/liblzo2.so.2*  /usr/lib/x86_64-linux-gnu/libudev.so.1* "$L/" 2>/dev/null || true

if [ ! -d "btrfs-progs-${VER}" ]; then
  log "fetching btrfs-progs ${VER} source"
  wget -q "https://mirrors.edge.kernel.org/pub/linux/kernel/people/kdave/btrfs-progs/btrfs-progs-${VER}.tar.xz" -O progs.tar.xz
  tar xf progs.tar.xz
fi
cd "btrfs-progs-${VER}"

log "configure + build: $TOOLS"
PKG_CONFIG_PATH="$L/pkgconfig:$SYS/usr/share/pkgconfig" PKG_CONFIG_SYSROOT_DIR="$SYS" \
CFLAGS="-I$SYS/usr/include -O2" LDFLAGS="-L$L" \
./configure --disable-documentation --disable-python --disable-convert >/dev/null
make -j"$(nproc)" $TOOLS

for t in $TOOLS; do
  # remove any box symlink masquerading as the tool, then install the real one
  rm -f "$R/usr/sbin/$t" "$R/usr/bin/$t" "$R/bin/$t" "$R/sbin/$t" 2>/dev/null || true
  install -m 755 "$t" "$R/usr/sbin/$t"
done
log "installed: $TOOLS -> $R/usr/sbin/"
