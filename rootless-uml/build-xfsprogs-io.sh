#!/bin/bash
# build-xfsprogs-io.sh — build latest xfs_io rootlessly and install into rootfs.
# Unlocks tests gated on newer xfs_io commands (exchangerange, pwrite -A, ...)
# and converts stale "xfs_io ... missing" notruns into honest fs-capability ones.
# Deps come from a deb-extracted sysroot (no sudo); gettext's msgfmt needs the
# sysroot on LD_LIBRARY_PATH; urcu headers live in the multiarch include dir;
# the ioctl dummy is C++ so CXXFLAGS must carry the same -I flags.
set -euo pipefail
BASE="${BASE:-$HOME/uml-smoke}"; R="$BASE/rootfs-xfs"
WORK="${WORK:-$BASE/xfsprogs-build}"; SYS="$WORK/sysroot"
mkdir -p "$WORK" && cd "$WORK"
for p in libinih-dev liburcu-dev libedit-dev uuid-dev libblkid-dev gettext gettext-base; do
  ls ${p}_*.deb >/dev/null 2>&1 || apt-get download "$p" >/dev/null 2>&1
done
for d in *.deb; do dpkg-deb -x "$d" "$SYS"; done
VER=$(curl -s https://www.kernel.org/pub/linux/utils/fs/xfs/xfsprogs/ \
      | grep -oE 'xfsprogs-[0-9.]+\.tar\.xz' | sort -V | tail -1)
[ -d "${VER%.tar.xz}" ] || { wget -q "https://www.kernel.org/pub/linux/utils/fs/xfs/xfsprogs/$VER"; tar xf "$VER"; }
cd "${VER%.tar.xz}"
export PATH="$SYS/usr/bin:$PATH" LD_LIBRARY_PATH="$SYS/usr/lib/x86_64-linux-gnu"
INC="-I$SYS/usr/include -I$SYS/usr/include/x86_64-linux-gnu"
PKG_CONFIG_PATH="$SYS/usr/lib/x86_64-linux-gnu/pkgconfig" PKG_CONFIG_SYSROOT_DIR="$SYS" \
CFLAGS="$INC -O2" CXXFLAGS="$INC -O2" LDFLAGS="-L$SYS/usr/lib/x86_64-linux-gnu" \
./configure --disable-docs >/dev/null
for d in libfrog libxcmd libhandle io; do make -j"$(nproc)" -C "$d" >/dev/null; done
# copy runtime libs the binary needs but the rootfs lacks
for f in $(ldd io/xfs_io | awk '/=>/{print $3}'); do
  b=$(basename "$f")
  ls "$R/usr/lib/x86_64-linux-gnu/$b" >/dev/null 2>&1 || cp -aL "$f" "$R/usr/lib/x86_64-linux-gnu/"
done
install -m 755 io/xfs_io "$R/usr/sbin/xfs_io"; rm -f "$R/usr/bin/xfs_io"
echo "installed: $("$R/usr/sbin/xfs_io" -V)"
