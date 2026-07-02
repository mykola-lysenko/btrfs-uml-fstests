#!/bin/bash
# build-uml-kernel.sh — build a UML (ARCH=um) kernel with btrfs, rootless.
#
# No sudo required. Downloads kernel source from GitHub codeload (cdn.kernel.org
# is blocked in some sandboxes; git.kernel.org cgit snapshots time out on the
# full tree). A UML defconfig kernel is tiny (~1k objects) and builds in ~30s on
# a many-core host.
#
# Usage: KVER=6.12 BASE=~/uml-smoke ./build-uml-kernel.sh
set -euo pipefail
KVER="${KVER:-6.12}"
BASE="${BASE:-$HOME/uml-smoke}"
SRC_URL="https://codeload.github.com/torvalds/linux/tar.gz/refs/tags/v${KVER}"
mkdir -p "$BASE"; cd "$BASE"
log(){ echo "[$(date '+%H:%M:%S')] $*"; }
t0=$(date +%s)

if [ ! -d "linux-${KVER}" ]; then
  [ -f "linux-${KVER}.tar.gz" ] || { log "Downloading linux-${KVER}..."; wget -q "$SRC_URL" -O "linux-${KVER}.tar.gz"; }
  log "Extracting ($(du -h "linux-${KVER}.tar.gz" | cut -f1))..."; tar xf "linux-${KVER}.tar.gz"
fi
cd "linux-${KVER}"

log "Configuring (ARCH=um defconfig + btrfs/dm/crypto)..."
make ARCH=um defconfig >/dev/null 2>&1
./scripts/config \
  --enable CONFIG_BTRFS_FS --enable CONFIG_BTRFS_FS_POSIX_ACL \
  --enable CONFIG_BTRFS_DEBUG --enable CONFIG_BTRFS_ASSERT \
  --enable CONFIG_BTRFS_FS_REF_VERIFY \
  --enable CONFIG_CRYPTO_CRC32C --enable CONFIG_CRYPTO_XXHASH \
  --enable CONFIG_CRYPTO_BLAKE2B --enable CONFIG_CRYPTO_ZSTD \
  --enable CONFIG_ZLIB_DEFLATE --enable CONFIG_LZO_COMPRESS --enable CONFIG_ZSTD_COMPRESS \
  --enable CONFIG_TMPFS --enable CONFIG_BLK_DEV_INITRD --enable CONFIG_BLK_DEV_UBD \
  `# device-mapper: unlocks dm-flakey / dm-log-writes crash-consistency tests in UML` \
  --enable CONFIG_MD --enable CONFIG_BLK_DEV_DM --enable CONFIG_DM_FLAKEY \
  --enable CONFIG_DM_LOG_WRITES --enable CONFIG_DM_SNAPSHOT --enable CONFIG_DM_ZERO \
  --enable CONFIG_DM_THIN_PROVISIONING --enable CONFIG_DM_DELAY --enable CONFIG_DM_ERROR \
  >/dev/null 2>&1
make ARCH=um olddefconfig >/dev/null 2>&1

log "Building UML kernel with $(nproc) cores..."
make ARCH=um -j"$(nproc)" >build.log 2>&1 \
  && log "BUILD OK ($(( $(date +%s)-t0 ))s): $(ls -lh linux | awk '{print $5}')" \
  || { log "BUILD FAILED"; tail -25 build.log; exit 1; }
log "kernel: $BASE/linux-${KVER}/linux"
