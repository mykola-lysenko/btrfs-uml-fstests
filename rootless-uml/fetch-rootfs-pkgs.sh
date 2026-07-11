#!/bin/bash
# fetch-rootfs-pkgs.sh — download a full rootfs package set, rootless.
#
# No sudo, no debootstrap. `apt-get download` needs no root; we resolve the FULL
# recursive dependency closure (including pre-depends) with apt-cache and download
# every .deb. Extract them with `assemble-rootfs.sh` afterwards.
#
# Host must be the same Ubuntu release you want in the guest (binaries run as-is).
#
# Usage: BASE=~/uml-smoke ./fetch-rootfs-pkgs.sh
set -uo pipefail
BASE="${BASE:-$HOME/uml-smoke}"
mkdir -p "$BASE/fullpkgs"; cd "$BASE"
log(){ echo "[$(date '+%H:%M:%S')] $*"; }

# Toolchain + xfstests build deps + runtime + the lib packages whose sonames the
# closure sometimes misses. libltdl-dev/xfslibs-dev are needed to BUILD xfstests.
PKGS="gcc g++ make autoconf automake libtool m4 gettext pkg-config libc6-dev linux-libc-dev \
uuid-dev libblkid-dev libattr1-dev libacl1-dev libaio-dev libltdl-dev xfslibs-dev \
bash coreutils util-linux mount attr acl btrfs-progs xfsprogs e2fsprogs \
fio gawk sed grep findutils perl diffutils file dash busybox-static \
bc psmisc procps time hostname \
libmount1 libsmartcols1 libfdisk1 libncursesw6 libtinfo6 libreadline8 ncurses-base \
libudev1 libselinux1 libpcre2-8-0 dmsetup libdevmapper1.02.1 \
quota fsverity libfsverity0 libtirpc3t64 libnsl2 libcap2-bin"

log "Computing full closure (incl pre-depends)..."
CLOSURE=$(apt-cache depends --recurse --no-recommends --no-suggests \
  --no-enhances --no-breaks --no-conflicts --no-replaces $PKGS \
  | grep '^\w' | grep -v '<' | sort -u)
log "closure: $(echo "$CLOSURE" | wc -l) packages"

cd fullpkgs
ok=0; new=0; fail=0
for p in $CLOSURE; do
  ls "${p}"_*.deb >/dev/null 2>&1 && { ok=$((ok+1)); continue; }
  if apt-get download "$p" >/dev/null 2>&1; then ok=$((ok+1)); new=$((new+1)); else fail=$((fail+1)); fi
done
log "have=$ok new=$new failed=$fail (fails are virtual pkgs, OK) size=$(du -sh . | cut -f1)"
