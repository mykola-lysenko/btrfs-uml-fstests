#!/bin/bash
# build-xfsprogs.sh — build the latest xfsprogs toolset rootlessly and install
# into the rootfs (mkfs.xfs, xfs_repair, xfs_db, xfs_io, xfs_logprint,
# xfs_growfs, xfs_spaceman, xfs_freeze, xfs_quota).
# WHY the full set, not just xfs_io: the Ubuntu-pool xfsprogs (6.6.0) is
# ~18 months older than the kernels under test; its xfs_repair called
# legitimate post-crash XFS_ATTR_INCOMPLETE entries corruption, which
# manufactured the generic/753+754 "fs inconsistent" finding, and its xfs_db
# output drift broke xfs/136. Record the version as XFSPROGS_VER in PINS
# and re-baseline after every bump.
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
make headers >/dev/null 2>&1
for d in libfrog libxcmd libhandle libxfs libxlog io mkfs repair db logprint growfs spaceman quota fsr; do
  make -j"$(nproc)" -C "$d" >/dev/null
done
BINS="io/xfs_io mkfs/mkfs.xfs repair/xfs_repair db/xfs_db logprint/xfs_logprint
      growfs/xfs_growfs spaceman/xfs_spaceman quota/xfs_quota fsr/xfs_fsr"
# copy runtime libs the binaries need but the rootfs lacks
for b in $BINS; do
  for f in $(ldd "$b" | awk '/=>/{print $3}'); do
    n=$(basename "$f")
    ls "$R/usr/lib/x86_64-linux-gnu/$n" >/dev/null 2>&1 || cp -aL "$f" "$R/usr/lib/x86_64-linux-gnu/"
  done
done
for b in $BINS; do
  n=$(basename "$b")
  install -m 755 "$b" "$R/usr/sbin/$n"; rm -f "$R/usr/bin/$n"
done
# xfs_freeze is a shell wrapper around xfs_io in upstream; keep distro copy.
echo "installed: $("$R/usr/sbin/xfs_io" -V), $("$R/usr/sbin/xfs_repair" -V), $("$R/usr/sbin/mkfs.xfs" -V)"
