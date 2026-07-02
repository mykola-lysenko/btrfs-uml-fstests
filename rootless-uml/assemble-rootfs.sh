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
