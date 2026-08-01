#!/bin/bash
# build-fuse2fs.sh — build fuse2fs at the PINned e2fsprogs version and install
# it into the rootfs, rootless. The noble pool only carries e2fsprogs 1.47.0;
# the fuse baseline was established on E2FSPROGS_VER (see PINS), and the rig's
# 1.47.4 binary predated repo discipline — the hosted lane exposed that gap
# (fuse guests: "/usr/bin/fuse2fs: not found").
set -euo pipefail
SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="${BASE:-$HOME/uml-smoke}"; R="$BASE/rootfs-xfs"
# shellcheck source=PINS
. "$SCRIPTDIR/PINS"
VER="${E2FSPROGS_VER:?E2FSPROGS_VER missing from PINS}"
WORK="$BASE/e2fsprogs-build"; SYS="$WORK/sysroot"
log(){ echo "[fuse2fs] $*"; }
mkdir -p "$WORK" && cd "$WORK"

for p in libfuse3-dev libfuse3-3 fuse3; do
  ls ${p}_*.deb >/dev/null 2>&1 || apt-get download "$p" >/dev/null 2>&1 || true
done
for d in *.deb; do
  # no bare '[ ] &&' as loop body: a false final iteration trips set -e
  if [ -f "$d" ]; then dpkg-deb -x "$d" "$SYS"; fi
done

SRC="e2fsprogs-$VER"
if [ ! -d "$SRC" ]; then
  log "downloading e2fsprogs v$VER..."
  wget -q "https://codeload.github.com/tytso/e2fsprogs/tar.gz/refs/tags/v$VER" -O "$SRC.tar.gz" \
    || { log "DOWNLOAD FAILED (codeload tytso v$VER)"; exit 1; }
  rm -rf _ex && mkdir _ex
  tar xf "$SRC.tar.gz" -C _ex || { log "EXTRACT FAILED"; exit 1; }
  mv _ex/* "$SRC" && rmdir _ex
fi
cd "$SRC"
INC="-I$SYS/usr/include -I$SYS/usr/include/x86_64-linux-gnu"
if [ ! -f Makefile ]; then
  PKG_CONFIG_PATH="$SYS/usr/lib/x86_64-linux-gnu/pkgconfig" PKG_CONFIG_SYSROOT_DIR="$SYS" \
  CFLAGS="$INC -O2" LDFLAGS="-L$SYS/usr/lib/x86_64-linux-gnu" \
  ./configure --disable-nls > configure.out 2>&1 \
    || { log "CONFIGURE FAILED:"; tail -15 configure.out; tail -25 config.log 2>/dev/null; exit 1; }
fi
make -j"$(nproc)" libs > build-libs.out 2>&1 \
  || { log "make libs FAILED:"; tail -25 build-libs.out; exit 1; }
make -j"$(nproc)" -C misc fuse2fs > build-fuse2fs.out 2>&1 \
  || { log "make fuse2fs FAILED:"; tail -25 build-fuse2fs.out; exit 1; }
[ -x misc/fuse2fs ] || { log "BUILD FAILED: misc/fuse2fs missing"; exit 1; }
# e2fsck + mke2fs at the SAME pin: the noble rootfs ships 1.47.0 for both,
# so the judge (e2fsck -fn in _check_fuse2fs_filesystem) and the formatter
# ran four minor versions behind the daemon under test — the exact
# stale-judging-binary trap the xfs generic/753+754 triage documented.
make -j"$(nproc)" -C e2fsck e2fsck > build-e2fsck.out 2>&1 \
  || { log "make e2fsck FAILED:"; tail -25 build-e2fsck.out; exit 1; }
make -j"$(nproc)" -C misc mke2fs > build-mke2fs.out 2>&1 \
  || { log "make mke2fs FAILED:"; tail -25 build-mke2fs.out; exit 1; }
[ -x e2fsck/e2fsck ] || { log "BUILD FAILED: e2fsck/e2fsck missing"; exit 1; }
[ -x misc/mke2fs ] || { log "BUILD FAILED: misc/mke2fs missing"; exit 1; }

install -m 755 misc/fuse2fs "$R/usr/bin/fuse2fs"
install -m 755 e2fsck/e2fsck "$R/usr/sbin/e2fsck"
# mkfs.ext4 in the rootfs is a symlink to mke2fs; replacing mke2fs covers it
install -m 755 misc/mke2fs "$R/usr/sbin/mke2fs"
# Ship the libfuse3 runtime the built binary actually needs. Two traps
# solved here: the guard must key on the binary's NEEDED soname (a
# hardcoded .so.N broke when fuse bumped sonames), and the runtime deb
# unpacks under lib/, not usr/lib/.
need=$(objdump -p misc/fuse2fs | awk '/NEEDED/ && /libfuse3/ {print $2}')
if [ -n "$need" ] && [ ! -e "$R/usr/lib/x86_64-linux-gnu/$need" ]; then
  cp -a "$SYS"/lib/x86_64-linux-gnu/libfuse3.so.* "$R/usr/lib/x86_64-linux-gnu/"
  log "added libfuse3 runtime ($need)"
fi
log "installed: $("$R/usr/bin/fuse2fs" -V 2>&1 | head -1 || true)"
log "installed: $("$R/usr/sbin/e2fsck" -V 2>&1 | head -1 || true)"
log "installed: $("$R/usr/sbin/mke2fs" -V 2>&1 | head -1 || true)"
