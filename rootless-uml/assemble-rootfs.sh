#!/bin/bash
# assemble-rootfs.sh — extract downloaded .debs into a rootfs tree, rootless.
#
# Recreates the bits dpkg's maintainer scripts normally do: merged-/usr symlinks
# and the update-alternatives aliases (awk, sh, aclocal, automake, logger). Also
# drops in busybox mount wrappers, because util-linux `mount` returns EPERM under
# UML even as uid 0 while busybox mount(2) works — see docs/HOWTO-xfstests-rootless.md.
#
# Usage: BASE=~/uml-smoke ./assemble-rootfs.sh
set -euo pipefail
BASE="${BASE:-$HOME/uml-smoke}"
R="$BASE/rootfs-xfs"
log(){ echo "[$(date '+%H:%M:%S')] $*"; }

rm -rf "$R"; mkdir -p "$R"; cd "$R"
log "Extracting $(ls "$BASE"/fullpkgs/*.deb | wc -l) packages..."
for d in "$BASE"/fullpkgs/*.deb; do dpkg-deb -x "$d" . 2>/dev/null; done

# getconf: some tests (e.g. btrfs/053) need it, but recent libc-bin debs omit the
# binary. Fall back to the host copy (tiny, links only libc which is in the rootfs).
if [ ! -x usr/bin/getconf ] && [ -x /usr/bin/getconf ]; then
  mkdir -p usr/bin; cp /usr/bin/getconf usr/bin/getconf; log "added getconf (from host)"
fi

# libproc2.so.0: procps `ps` needs it (e.g. btrfs/036); some deb sets ship ps but
# not the split-out libproc2-0. Fall back to the host copy.
if ! ls usr/lib/x86_64-linux-gnu/libproc2.so.0* >/dev/null 2>&1 \
   && ls /usr/lib/x86_64-linux-gnu/libproc2.so.0* >/dev/null 2>&1; then
  mkdir -p usr/lib/x86_64-linux-gnu
  cp -a /usr/lib/x86_64-linux-gnu/libproc2.so.0* usr/lib/x86_64-linux-gnu/
  log "added libproc2 (from host)"
fi

# setuid bits: dpkg-deb -x preserves the setuid BIT but ownership becomes the
# assembling uid (1000) — which in the guest is fsgqa. A setuid-fsgqa mount
# DROPS root to uid 1000, so mount(2) gets EPERM: the long-standing
# "must be superuser to use mount" (in QEMU too) was exactly this. Root
# needs no setuid, so strip the bit everywhere.
find . -perm -4000 -type f -exec chmod u-s {} + 2>/dev/null
log "stripped setuid bits (they were setuid-uid1000, breaking mount as root)"

# /etc/mtab for util-linux tools
ln -sfn ../proc/self/mounts etc/mtab

# name resolution: src/locktest (generic/131,571,786,787) resolves "localhost";
# without /etc/hosts + nsswitch, gethostbyname fails ("Couldn't get hostbyname").
printf '127.0.0.1\tlocalhost\n::1\tlocalhost\n' > etc/hosts
printf 'hosts: files dns\npasswd: files\ngroup: files\n' > etc/nsswitch.conf

# su: util-linux su is PAM-based and the rootfs has no PAM stack, so
# `su fsgqa -c ...` fails ("fsgqa cannot execute commands") and ~27 tests
# notrun. Route su through busybox (PAM-free); /usr/local/bin wins on PATH.
mkdir -p usr/local/bin
printf '#!/bin/sh\nexec /usr/bin/busybox su "$@"\n' > usr/local/bin/su
chmod 755 usr/local/bin/su
log "added busybox su wrapper (PAM-free)"

# fsgqa home dirs (tests run commands as fsgqa/fsgqa2)
mkdir -p home/fsgqa home/fsgqa2
chmod 777 home/fsgqa home/fsgqa2

log "Merged-/usr symlinks..."
for dir in bin sbin lib lib64; do
  if [ -d "$dir" ] && [ ! -L "$dir" ]; then
    mkdir -p "usr/$dir"; cp -a "$dir/." "usr/$dir/" 2>/dev/null; rm -rf "$dir"
  fi
  ln -sfn "usr/$dir" "$dir"
done

log "update-alternatives aliases..."
cd usr/bin
[ -e awk ]      || ln -s gawk awk
[ -e sh ]       || ln -s dash sh
[ -e aclocal ]  || ln -s aclocal-1.16 aclocal
[ -e automake ] || ln -s automake-1.16 automake
[ -e logger ]   || ln -s busybox logger
cd "$R"

log "busybox mount wrappers (util-linux mount EPERMs under UML)..."
mkdir -p usr/local/bin
printf '#!/bin/bash\nexec /usr/bin/busybox mount "$@"\n'  > usr/local/bin/bbmount
printf '#!/bin/bash\nexec /usr/bin/busybox umount "$@"\n' > usr/local/bin/bbumount
chmod +x usr/local/bin/bbmount usr/local/bin/bbumount

log "minimal /etc (xfstests needs fsgqa users or many tests _notrun)..."
mkdir -p etc home/fsgqa home/fsgqa2 mnt/test mnt/scratch host results
cat > etc/passwd <<'P'
root:x:0:0:root:/root:/bin/bash
nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin
fsgqa:x:1000:1000:fsgqa:/home/fsgqa:/bin/bash
123456-fsgqa:x:1001:1001:fsgqa:/home/fsgqa:/bin/bash
fsgqa2:x:1002:1002:fsgqa2:/home/fsgqa2:/bin/bash
P
cat > etc/group <<'G'
root:x:0:
nogroup:x:65534:
fsgqa:x:1000:
fsgqa2:x:1002:
G
printf 'passwd: files\ngroup: files\nhosts: files\n' > etc/nsswitch.conf

# Full library-closure sanity check (counts symlinks too).
log "unresolved shared libs (should be empty):"
find . \( -type f -o -type l \) -name '*.so*' 2>/dev/null | sed 's|.*/||' | sort -u > /tmp/_have
{ find usr/bin usr/sbin -type f 2>/dev/null; find . \( -type f -o -type l \) -name '*.so*'; } \
  | while read -r f; do readelf -d "$f" 2>/dev/null | awk '/NEEDED/{gsub(/[][]/,"",$5);print $5}'; done \
  | sort -u > /tmp/_need
comm -23 /tmp/_need /tmp/_have | sed 's/^/  MISSING: /'
log "rootfs assembled at $R ($(du -sh "$R" | cut -f1))"
