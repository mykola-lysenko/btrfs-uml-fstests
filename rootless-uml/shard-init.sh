#!/bin/bash
# shard-init.sh — UML guest PID1 for one shard of a parallel xfstests run.
#
# Reads its shard id from the kernel command line (shard=N), then runs its slice
# of tests (from /host/shards/N/RUN_ARGS) and writes results to
# /host/shards/N/results. The rootfs is shared read-only across all shards via
# hostfs; only per-shard subdirs and each shard's own ubd images are written, so
# many shards run concurrently without contention (one UML per image set — UML
# flocks its backing files).
#
# HOST_DIR must match the hostfs rootflags path.
HOST_DIR=/home/prozak/uml-smoke

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HOME=/root TMPDIR=/tmp
BB=/usr/bin/busybox
$BB mount -t proc proc /proc
$BB mount -t sysfs sysfs /sys
$BB mount -t devtmpfs devtmpfs /dev 2>/dev/null
$BB mount -t tmpfs -o size=90% tmpfs /tmp
$BB mount -t tmpfs tmpfs /run 2>/dev/null
mkdir -p /dev/shm; $BB mount -t tmpfs tmpfs /dev/shm 2>/dev/null

SHARD=$($BB tr ' ' '\n' < /proc/cmdline | $BB sed -n 's/^shard=//p')
[ -z "$SHARD" ] && SHARD=0
$BB hostname "uml-shard-$SHARD"
$BB mount -t hostfs -o "$HOST_DIR" none /host 2>/dev/null || echo "HOSTFS_FAIL"
SDIR="/host/shards/$SHARD"
mkdir -p "$SDIR/results"
echo "==== SHARD $SHARD ($(uname -r)) ===="

# Restore the shared prebuilt tree to this shard's tmpfs (34 MB, fast).
cp -a /host/xfstests-built /tmp/xfstests
cd /tmp/xfstests
cat > local.config <<CFG
FSTYP=btrfs
TEST_DEV=/dev/ubdb
TEST_DIR=/mnt/test
SCRATCH_DEV=/dev/ubdc
SCRATCH_MNT=/mnt/scratch
RESULT_BASE=$SDIR/results
MOUNT_PROG=/usr/local/bin/bbmount
UMOUNT_PROG=/usr/local/bin/bbumount
CFG
mkdir -p /mnt/test /mnt/scratch; chmod 777 /mnt/test /mnt/scratch
ARGS="$($BB cat "$SDIR/RUN_ARGS" 2>/dev/null)"
if [ -z "$ARGS" ]; then echo "SHARD $SHARD: empty RUN_ARGS"; else
  mkfs.btrfs -f -q /dev/ubdb >/dev/null 2>&1
  ./check $ARGS >"$SDIR/results/run.log" 2>&1
fi
echo "==== SHARD $SHARD DONE (uptime $($BB cut -d. -f1 /proc/uptime)s) ===="
sync
$BB poweroff -f 2>/dev/null; $BB halt -f
