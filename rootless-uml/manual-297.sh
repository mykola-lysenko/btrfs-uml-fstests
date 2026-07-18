#!/bin/bash
# manual-297.sh — boot-to-ready interactive guest for hands-on xfstests work.
# Use as init=: does the full shard-init-style setup (mounts, xfstests copy,
# local.config with a btrfs raid pool, test-dev mkfs), then drops you into an
# interactive shell in /tmp/xfstests where `./check btrfs/297` just works.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HOME=/root TMPDIR=/tmp TERM=linux
BB=/usr/bin/busybox
$BB mount -t proc proc /proc; $BB mount -t sysfs sysfs /sys
$BB mount -t devtmpfs devtmpfs /dev 2>/dev/null
$BB mount -t tmpfs -o size=90% tmpfs /tmp
$BB mount -t tmpfs tmpfs /mnt; mkdir -p /mnt/test /mnt/scratch
$BB mount -t hostfs -o /home/prozak/uml-smoke none /host 2>/dev/null
$BB ip link set lo up 2>/dev/null

cp -a /host/xfstests-built /tmp/xfstests
cd /tmp/xfstests
{
echo 'FSTYP=btrfs'
echo 'TEST_DEV=/dev/ubdb'
echo 'TEST_DIR=/mnt/test'
echo 'SCRATCH_MNT=/mnt/scratch'
echo 'SCRATCH_DEV_POOL="/dev/ubdc /dev/ubdd /dev/ubde /dev/ubdf /dev/ubdg"'
echo 'RESULT_BASE=/tmp/results'
} > local.config
mkfs.btrfs -f -q /dev/ubdb
export DM_DISABLE_UDEV=1 FSTESTS_PER_TEST_TIMEOUT=1300

echo ""
echo "=== ready in /tmp/xfstests — try: ./check btrfs/297 ==="
echo "=== results land in /tmp/results; leave with: halt -f ==="
exec bash -i
