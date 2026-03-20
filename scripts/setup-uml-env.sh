#!/bin/bash
# setup-uml-env.sh — End-to-end UML + BTRFS fstests environment setup
# Idempotent: skips steps already completed (checks for output files)
set -euo pipefail
BASE=/home/ubuntu
KVER=""  # auto-detect latest stable

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# ── 1. Dependencies ───────────────────────────────────────────────────────────
log "Installing build dependencies..."
sudo apt-get update -qq
sudo apt-get install -y --no-install-recommends \
  build-essential flex bison bc libelf-dev libssl-dev libncurses-dev \
  debootstrap git make gcc autoconf automake libtool pkg-config \
  libblkid-dev libreadline-dev libuuid1 uuid-dev libacl1-dev libattr1-dev \
  xfslibs-dev e2fsprogs btrfs-progs 2>&1 | tail -3

# ── 2. Kernel source ──────────────────────────────────────────────────────────
if [ ! -d "$BASE/linux-6.19.9" ]; then
  log "Fetching latest stable kernel..."
  KVER=$(curl -s https://www.kernel.org/releases.json | python3 -c \
    "import sys,json; r=json.load(sys.stdin)['releases']; \
     print(next(x['version'] for x in r if x['moniker']=='stable'))")
  log "Latest stable: $KVER"
  cd "$BASE"
  wget -q "https://cdn.kernel.org/pub/linux/kernel/v${KVER%%.*}.x/linux-${KVER}.tar.xz"
  tar xf "linux-${KVER}.tar.xz"
  mv "linux-${KVER}" linux-6.19.9 2>/dev/null || true
  log "Kernel source extracted"
else
  log "Kernel source already present, skipping download"
fi

# ── 3. Build UML kernel ───────────────────────────────────────────────────────
if [ ! -f "$BASE/linux-6.19.9/linux" ]; then
  log "Configuring UML kernel..."
  cd "$BASE/linux-6.19.9"
  make ARCH=um defconfig 2>&1 | tail -2
  ./scripts/config \
    --enable CONFIG_BTRFS_FS \
    --enable CONFIG_BTRFS_FS_POSIX_ACL \
    --enable CONFIG_BTRFS_FS_CHECK_INTEGRITY \
    --enable CONFIG_BTRFS_DEBUG \
    --enable CONFIG_BTRFS_ASSERT \
    --enable CONFIG_BTRFS_FS_REF_VERIFY \
    --enable CONFIG_BTRFS_FS_RUN_SANITY_TESTS \
    --enable CONFIG_FS_VERITY \
    --enable CONFIG_FSCRYPT \
    --enable CONFIG_QUOTA \
    --enable CONFIG_QUOTA_NETLINK_INTERFACE \
    --enable CONFIG_QFMT_V2 \
    --enable CONFIG_FS_POSIX_ACL \
    --enable CONFIG_TMPFS \
    --enable CONFIG_TMPFS_POSIX_ACL \
    --enable CONFIG_OVERLAY_FS \
    --enable CONFIG_CRYPTO_USER_API_HASH \
    --enable CONFIG_CRYPTO_SHA256 \
    --enable CONFIG_CRYPTO_CRC32C \
    --enable CONFIG_CRYPTO_XXHASH \
    --enable CONFIG_CRYPTO_BLAKE2B \
    --enable CONFIG_CRYPTO_ZSTD \
    --enable CONFIG_ZLIB_DEFLATE \
    --enable CONFIG_LZO_COMPRESS \
    --enable CONFIG_ZSTD_COMPRESS \
    2>&1 | tail -2
  make ARCH=um olddefconfig 2>&1 | tail -2
  log "Building UML kernel (using $(nproc) CPUs)..."
  make ARCH=um -j$(nproc) 2>&1 | tail -3
  log "UML kernel built: $(ls -lh linux)"
else
  log "UML kernel already built, skipping"
fi

# ── 4. Root filesystem ────────────────────────────────────────────────────────
if [ ! -d "$BASE/uml-rootfs/opt/xfstests" ]; then
  log "Creating Debian bookworm rootfs..."
  sudo mkdir -p "$BASE/uml-rootfs"
  sudo debootstrap --arch=amd64 bookworm "$BASE/uml-rootfs" \
    http://deb.debian.org/debian 2>&1 | tail -3

  log "Installing packages in rootfs..."
  sudo chroot "$BASE/uml-rootfs" /bin/bash -c "
    apt-get install -y --no-install-recommends \
      btrfs-progs xfsprogs e2fsprogs attr acl \
      fio dbench libaio1 libgdbm6 libacl1 libattr1 \
      uuid-runtime bc gawk python3 perl \
      git make gcc autoconf automake libtool \
      pkg-config libblkid-dev libreadline-dev \
      libuuid1 uuid-dev libacl1-dev libattr1-dev \
      xfslibs-dev 2>&1 | tail -3
  "

  log "Cloning and building xfstests..."
  git clone --depth=1 https://git.kernel.org/pub/scm/fs/xfs/xfstests-dev.git "$BASE/xfstests" 2>&1 | tail -2
  sudo cp -a "$BASE/xfstests" "$BASE/uml-rootfs/opt/xfstests"
  sudo chroot "$BASE/uml-rootfs" /bin/bash -c "
    cd /opt/xfstests && make 2>&1 | tail -3
  "
  log "xfstests built"
else
  log "rootfs already prepared, skipping"
fi

# ── 5. Generate test list ─────────────────────────────────────────────────────
if [ ! -f "$BASE/uml_all_auto_tests.txt" ]; then
  log "Generating compatible test list..."
  cd "$BASE/xfstests"
  python3 << 'PYEOF'
import os, re, sys
test_dir = "tests"
uml_blocklist = {
    "_require_dm_target", "_require_scratch_dev_pool",
    "_require_log_writes", "_require_realtime",
    "_require_scratch_nocheck", "_require_multi_disks",
}
xfs_only = {"_require_xfs_", "_require_scratch_xfs", "xfs_"}
tier1, tier2 = [], []
for fstype in ["btrfs", "generic"]:
    tdir = os.path.join(test_dir, fstype)
    if not os.path.isdir(tdir): continue
    for fname in sorted(os.listdir(tdir)):
        if not fname.isdigit(): continue
        try: content = open(os.path.join(tdir, fname)).read()
        except: continue
        if fstype == "generic" and any(x in content for x in xfs_only): continue
        if any(x in content for x in uml_blocklist): continue
        groups = re.search(r'_begin_fstest\s+(.*)', content)
        groups = groups.group(1).split() if groups else []
        tid = f"{fstype}/{fname}"
        if "quick" in groups: tier1.append(tid)
        elif "auto" in groups: tier2.append(tid)
all_tests = tier1 + tier2
with open("/home/ubuntu/uml_all_auto_tests.txt", "w") as f:
    f.write("\n".join(all_tests) + "\n")
with open("/home/ubuntu/uml_quick_tests.txt", "w") as f:
    f.write("\n".join(tier1) + "\n")
print(f"Quick: {len(tier1)}, Auto: {len(tier2)}, Total: {len(all_tests)}")
PYEOF
else
  log "Test list already exists ($(wc -l < $BASE/uml_all_auto_tests.txt) tests)"
fi

# ── 6. Install scripts and config into rootfs ─────────────────────────────────
log "Installing init scripts and config into rootfs..."
sudo mkdir -p "$BASE/uml-rootfs/mnt/test" "$BASE/uml-rootfs/mnt/scratch" \
              "$BASE/uml-rootfs/results"

# local.config
sudo tee "$BASE/uml-rootfs/opt/xfstests/local.config" > /dev/null << 'EOF'
FSTYP=btrfs
TEST_DEV=/dev/ubdb
TEST_DIR=/mnt/test
SCRATCH_DEV=/dev/ubdc
SCRATCH_MNT=/mnt/scratch
RESULT_BASE=/results
RECREATE_TEST_DEV=true
EOF

# test list
sudo cp "$BASE/uml_all_auto_tests.txt" \
        "$BASE/uml-rootfs/opt/xfstests/uml_test_list.txt"

# run-fstests.sh init script
sudo tee "$BASE/uml-rootfs/sbin/run-fstests.sh" > /dev/null << 'INIT'
#!/bin/bash
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t devtmpfs devtmpfs /dev 2>/dev/null
mount -t devpts devpts /dev/pts 2>/dev/null
mount -t tmpfs tmpfs /tmp 2>/dev/null
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
hostname uml-fstests
mkdir -p /mnt/test /mnt/scratch /results
echo "=== UML fstests start at $(date) ==="
echo "=== Kernel: $(uname -r) ==="
mkfs.btrfs -f /dev/ubdb 2>&1 | tail -3
cd /opt/xfstests
./check $(cat /opt/xfstests/uml_test_list.txt | tr '\n' ' ') 2>&1 | tee /results/fstests_output.txt
echo "=== fstests done at $(date) ==="
echo "FSTESTS_DONE" >> /results/fstests_output.txt
sync
echo 1 > /proc/sys/kernel/sysrq
echo o > /proc/sysrq-trigger
sleep 10
INIT
sudo chmod +x "$BASE/uml-rootfs/sbin/run-fstests.sh"

# validate-init.sh
sudo tee "$BASE/uml-rootfs/sbin/validate-init.sh" > /dev/null << 'INIT'
#!/bin/bash
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t devtmpfs devtmpfs /dev 2>/dev/null
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
echo "=== VALIDATE: kernel $(uname -r) ==="
mkfs.btrfs -f /dev/ubdb 2>&1 | grep -E "UUID|error" | head -2
mkdir -p /mnt/test
mount -t btrfs /dev/ubdb /mnt/test 2>&1 && echo "BTRFS MOUNT OK" || echo "BTRFS MOUNT FAIL"
umount /mnt/test 2>/dev/null
echo "=== VALIDATE DONE ==="
sync
echo 1 > /proc/sys/kernel/sysrq
echo o > /proc/sysrq-trigger
INIT
sudo chmod +x "$BASE/uml-rootfs/sbin/validate-init.sh"

# ── 7. Create disk images ─────────────────────────────────────────────────────
if [ ! -f "$BASE/rootfs.img" ]; then
  log "Creating rootfs.img..."
  IMG_MB=$(sudo du -sm "$BASE/uml-rootfs" 2>/dev/null | awk '{print $1 + 700}')
  dd if=/dev/zero of="$BASE/rootfs.img" bs=1M count="$IMG_MB" status=none
  mkfs.ext4 -q "$BASE/rootfs.img"
  sudo mkdir -p "$BASE/img-mount"
  sudo mount -o loop "$BASE/rootfs.img" "$BASE/img-mount"
  sudo cp -a "$BASE/uml-rootfs/." "$BASE/img-mount/"
  sudo umount "$BASE/img-mount"
  sudo chown ubuntu:ubuntu "$BASE/rootfs.img"
  log "rootfs.img created: $(ls -lh $BASE/rootfs.img)"
else
  log "rootfs.img already exists"
fi

if [ ! -f "$BASE/test.img" ]; then
  log "Creating test.img and scratch.img..."
  truncate -s 10G "$BASE/test.img"
  truncate -s 10G "$BASE/scratch.img"
  sudo chown ubuntu:ubuntu "$BASE/test.img" "$BASE/scratch.img"
  log "Disk images created"
else
  log "Disk images already exist"
fi

# ── 8. Validation boot ────────────────────────────────────────────────────────
log "Running UML validation boot..."
RESULT=$(timeout 45 "$BASE/linux-6.19.9/linux" \
  ubda="$BASE/rootfs.img" \
  ubdb="$BASE/test.img" \
  ubdc="$BASE/scratch.img" \
  mem=512M root=/dev/ubda rootfstype=ext4 rw \
  con=null con0=fd:0,fd:1 \
  init=/sbin/validate-init.sh \
  2>&1 | grep -E "VALIDATE|BTRFS MOUNT|panic")
echo "$RESULT"
if echo "$RESULT" | grep -q "BTRFS MOUNT OK"; then
  log "✓ Validation passed — UML boots and BTRFS works"
else
  log "✗ Validation FAILED"
  exit 1
fi

log "=== Setup complete ==="
log "UML kernel: $BASE/linux-6.19.9/linux"
log "rootfs:     $BASE/rootfs.img"
log "Test list:  $BASE/uml_all_auto_tests.txt ($(wc -l < $BASE/uml_all_auto_tests.txt) tests)"
