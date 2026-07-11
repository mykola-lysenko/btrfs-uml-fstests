#!/bin/bash
set -e
BASE=~/uml-smoke; NAME="$1"; TARBALL="$BASE/linux-${NAME}.tar.gz"
DST="$BASE/x86-${NAME}"
echo "[x86] extracting $NAME..."
rm -rf "$DST" _x86ex && mkdir _x86ex && tar xf "$TARBALL" -C _x86ex && mv _x86ex/* "$DST" && rmdir _x86ex
cd "$DST"
echo "[x86] configuring x86_64 + btrfs + virtio (builtin, no initramfs)..."
make x86_64_defconfig >/dev/null 2>&1
./scripts/config \
  --enable BTRFS_FS --enable BTRFS_FS_POSIX_ACL --enable BTRFS_FS_CHECK_INTEGRITY \
  --enable VIRTIO --enable VIRTIO_PCI --enable VIRTIO_BLK --enable VIRTIO_CONSOLE \
  --enable EXT4_FS --enable SERIAL_8250 --enable SERIAL_8250_CONSOLE \
  --enable BLK_DEV --enable DEVTMPFS --enable DEVTMPFS_MOUNT \
  --enable FS_VERITY --enable FS_VERITY_BUILTIN_SIGNATURES --enable BLK_DEV_LOOP \
  --enable BLK_DEV_DM --enable DM_FLAKEY --enable DM_LOG_WRITES --enable DM_SNAPSHOT \
  --enable DM_THIN_PROVISIONING --enable DM_DELAY --enable DM_ZERO --enable MD
make olddefconfig >/dev/null 2>&1
echo "[x86] building bzImage ($(nproc) cores)..."
t0=$(date +%s)
make -j"$(nproc)" bzImage >build-x86.log 2>&1 && echo "[x86] BUILT $NAME in $(( $(date +%s)-t0 ))s: $(ls -la arch/x86/boot/bzImage | awk '{print $5}')" || { echo "[x86] BUILD FAILED"; tail -15 build-x86.log; exit 1; }
