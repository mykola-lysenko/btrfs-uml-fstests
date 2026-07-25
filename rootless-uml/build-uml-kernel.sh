#!/bin/bash
# build-uml-kernel.sh — build a UML (ARCH=um) kernel with btrfs, rootless.
#
# No sudo required. Downloads kernel source from GitHub codeload (cdn.kernel.org
# is blocked in some sandboxes; git.kernel.org cgit snapshots time out on the
# full tree). A UML defconfig kernel is tiny (~1k objects) and builds in ~30s on
# a many-core host.
#
# Source selection (pick what "upstream" means for you):
#   Mainline release:   REPO=torvalds/linux    REF=tags/v6.12         (default)
#   Mainline tip:       REPO=torvalds/linux     REF=heads/master
#   btrfs dev tree:     REPO=kdave/btrfs-devel  REF=heads/for-next    <-- for btrfs bug finding
#   btrfs misc-next:    REPO=kdave/btrfs-devel  REF=heads/misc-next
# NAME defaults to a slug of REF; a branch tarball is a moving snapshot, so the
# build records the source and HEAD in $DIR/SOURCE.txt for reproducibility.
#
# Usage: REPO=kdave/btrfs-devel REF=heads/for-next NAME=btrfs-for-next ./build-uml-kernel.sh
set -euo pipefail
SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="${BASE:-$HOME/uml-smoke}"
REPO="${REPO:-torvalds/linux}"
REF="${REF:-tags/v${KVER:-6.12}}"
NAME="${NAME:-$(echo "$REF" | sed 's#.*/##')}"
# A bare commit SHA as REF (the PINS advance path) downloads that exact
# commit — reproducible, unlike a moving branch tarball.
if echo "$REF" | grep -qE '^[0-9a-f]{7,40}$'; then
  SRC_URL="https://codeload.github.com/${REPO}/tar.gz/${REF}"
else
  SRC_URL="https://codeload.github.com/${REPO}/tar.gz/refs/${REF}"
fi
DIR="linux-${NAME}"
mkdir -p "$BASE"; cd "$BASE"
log(){ echo "[$(date '+%H:%M:%S')] $*"; }
t0=$(date +%s)

if [ ! -d "$DIR" ]; then
  if echo "$REPO" | grep -q '://'; then
    # Non-GitHub upstream (e.g. git.kernel.org xfs-linux): shallow git fetch.
    # Works with a branch name or a bare SHA REF; cgit *snapshot tarballs*
    # time out on full trees, but the git transport itself is fine (~280M).
    log "Shallow-fetching ${REPO} ${REF}..."
    git init -q "$DIR"
    git -C "$DIR" fetch -q --depth 1 "$REPO" "$REF" \
      || { log "GIT FETCH FAILED: $REPO $REF"; rm -rf "$DIR"; exit 1; }
    git -C "$DIR" checkout -q FETCH_HEAD
    git -C "$DIR" rev-parse FETCH_HEAD > "$DIR/.source-sha"
  else
  [ -f "${DIR}.tar.gz" ] || { log "Downloading ${REPO} ${REF}..."; wget -q "$SRC_URL" -O "${DIR}.tar.gz"; }
  log "Extracting ($(du -h "${DIR}.tar.gz" | cut -f1))..."
  # GitHub tarballs unpack to <repo>-<ref-slug>/ ; extract to a temp dir then
  # normalize to $DIR (avoids `tar t | head`, which trips SIGPIPE under pipefail).
  rm -rf _extract && mkdir _extract
  tar xf "${DIR}.tar.gz" -C _extract
  mv _extract/* "$DIR"; rmdir _extract
  fi
  # Apply local kernel patches once, on fresh extraction (e.g. the experimental
  # UML adaptive-spin handoff). Set UML_PATCHES=none to skip.
  PATCHDIR="${UML_PATCHES:-$SCRIPTDIR/patches}"
  if [ "$PATCHDIR" != none ] && ls "$PATCHDIR"/*.patch >/dev/null 2>&1; then
    for p in "$PATCHDIR"/*.patch; do
      log "Applying $(basename "$p")..."
      (cd "$DIR" && patch -p1 --no-backup-if-mismatch < "$p") \
        || { log "PATCH FAILED: $p"; exit 1; }
    done
  fi
fi
cd "$DIR"
printf 'repo=%s\nref=%s\nsha=%s\nfetched=%s\nversion=%s\n' "$REPO" "$REF" \
  "$(cat .source-sha 2>/dev/null || echo "$REF")" "$(date -u +%FT%TZ)" \
  "$(make kernelversion 2>/dev/null)" > SOURCE.txt

# FLAVOR selects which filesystem(s) get built in: btrfs (default), xfs,
# fuse, or trifs (all three — the smoke-gate style kernel). Per-fs PINS
# kernels use their own flavor so each fs sweeps its own upstream.
FLAVOR="${FLAVOR:-btrfs}"
log "Configuring (ARCH=um defconfig, flavor=$FLAVOR)..."
make ARCH=um defconfig >/dev/null 2>&1
./scripts/config \
  --enable CONFIG_CRYPTO_CRC32C --enable CONFIG_CRYPTO_XXHASH \
  --enable CONFIG_CRYPTO_BLAKE2B --enable CONFIG_CRYPTO_ZSTD \
  --enable CONFIG_ZLIB_DEFLATE --enable CONFIG_LZO_COMPRESS --enable CONFIG_ZSTD_COMPRESS \
  --enable CONFIG_TMPFS --enable CONFIG_BLK_DEV_INITRD --enable CONFIG_BLK_DEV_UBD \
  `# tmpfs xattr/acl: generic/270-class setcap-on-/tmp failures (xfs triage)` \
  --enable CONFIG_TMPFS_XATTR --enable CONFIG_TMPFS_POSIX_ACL \
  `# device-mapper: unlocks dm-flakey / dm-log-writes crash-consistency tests in UML` \
  --enable CONFIG_MD --enable CONFIG_BLK_DEV_DM --enable CONFIG_DM_FLAKEY \
  --enable CONFIG_DM_LOG_WRITES --enable CONFIG_DM_SNAPSHOT --enable CONFIG_DM_ZERO \
  --enable CONFIG_DM_THIN_PROVISIONING --enable CONFIG_DM_DELAY --enable CONFIG_DM_ERROR \
  `# loop devices (generic/042 etc); verity + fault-injection coverage` \
  --enable CONFIG_BLK_DEV_LOOP --enable CONFIG_FS_VERITY --enable CONFIG_FS_VERITY_BUILTIN_SIGNATURES \
  --enable CONFIG_FAULT_INJECTION --enable CONFIG_FAULT_INJECTION_DEBUG_FS --enable CONFIG_FAIL_MAKE_REQUEST \
  >/dev/null 2>&1
cfg_btrfs(){ ./scripts/config \
  --enable CONFIG_BTRFS_FS --enable CONFIG_BTRFS_FS_POSIX_ACL \
  --enable CONFIG_BTRFS_DEBUG --enable CONFIG_BTRFS_ASSERT \
  --enable CONFIG_BTRFS_FS_REF_VERIFY >/dev/null 2>&1; }
cfg_xfs(){ ./scripts/config \
  --enable CONFIG_XFS_FS --enable CONFIG_XFS_QUOTA --enable CONFIG_XFS_POSIX_ACL \
  --enable CONFIG_XFS_RT --enable CONFIG_XFS_ONLINE_SCRUB --enable CONFIG_XFS_ONLINE_REPAIR \
  --enable CONFIG_XFS_DEBUG --enable CONFIG_XFS_ASSERT_FATAL >/dev/null 2>&1; }
cfg_fuse(){ ./scripts/config \
  --enable CONFIG_FUSE_FS --enable CONFIG_FUSE_PASSTHROUGH --enable CONFIG_FUSE_IO_URING \
  --enable CONFIG_EXT4_FS --enable CONFIG_EXT4_USE_FOR_EXT2 >/dev/null 2>&1; }
case "$FLAVOR" in
  btrfs) cfg_btrfs ;;
  xfs)   cfg_xfs ;;
  fuse)  cfg_fuse ;;
  trifs) cfg_btrfs; cfg_xfs; cfg_fuse ;;
  *) log "unknown FLAVOR=$FLAVOR (btrfs|xfs|fuse|trifs)"; exit 1 ;;
esac
make ARCH=um olddefconfig >/dev/null 2>&1

log "Building UML kernel with $(nproc) cores..."
make ARCH=um -j"$(nproc)" >build.log 2>&1 \
  && log "BUILD OK ($(( $(date +%s)-t0 ))s): $(ls -lh linux | awk '{print $5}')" \
  || { log "BUILD FAILED"; tail -25 build.log; exit 1; }
log "kernel: $BASE/$DIR/linux  ($(cat SOURCE.txt | tr '\n' ' '))"
