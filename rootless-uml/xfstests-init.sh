#!/bin/bash
# xfstests-init.sh — UML guest init (PID 1) that runs xfstests against btrfs.
#
# Boot with this as init, root served from the assembled rootfs via hostfs:
#   timeout 900 $BASE/linux-<ver>/linux \
#     rootfstype=hostfs rootflags=$BASE/rootfs-xfs rw init=/xfstests-init.sh \
#     ubda=$BASE/ubda_dummy.img ubdb=$BASE/test.img ubdc=$BASE/test2.img \
#     mem=8000M con0=fd:0,fd:1 con=null
#
# Device note: UML sets a phantom root=98:0 (=/dev/ubda), so TEST/SCRATCH must NOT
# be ubda. Pass a dummy ubda (so the ubd subsystem sets up /dev/ubdb,c), use
# ubdb=TEST, ubdc=SCRATCH. Run ONE UML per image set (UML flocks backing files).
#
# HOST_DIR must match the hostfs rootflags path (where results/ and the prebuilt
# xfstests-built/ tree live). Edit if your workdir differs.
HOST_DIR=/home/prozak/uml-smoke

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HOME=/root TMPDIR=/tmp
BB=/usr/bin/busybox   # util-linux mount EPERMs under UML; busybox mount works
$BB mount -t proc proc /proc
$BB mount -t sysfs sysfs /sys
$BB mount -t devtmpfs devtmpfs /dev 2>/dev/null
$BB mount -t tmpfs -o size=90% tmpfs /tmp
$BB mount -t tmpfs tmpfs /run 2>/dev/null
mkdir -p /dev/pts /dev/shm
$BB mount -t devpts devpts /dev/pts 2>/dev/null; $BB mount -t tmpfs tmpfs /dev/shm 2>/dev/null
hostname uml-xfstests
$BB mount -t hostfs -o "$HOST_DIR" none /host 2>/dev/null || echo "HOSTFS_FAIL"
echo "==== UML XFSTESTS RUNNER ($(uname -r)) ===="
[ -d /host/results ] || mkdir -p /host/results

# Restore the host-built tree to tmpfs (fast); fall back to an in-guest build.
if [ -f /host/xfstests-built/ltp/fsstress ]; then
  echo "-- restoring prebuilt tree to tmpfs --"; cp -a /host/xfstests-built /tmp/xfstests
else
  echo "-- building in tmpfs (slow) --"; cp -a /host/xfstests-master /tmp/xfstests
  ( cd /tmp/xfstests && make -j2 ) >/host/results/build.log 2>&1 && echo BUILD_OK || echo BUILD_FAIL
fi
cd /tmp/xfstests
cat > local.config <<CFG
FSTYP=btrfs
TEST_DEV=/dev/ubdb
TEST_DIR=/mnt/test
SCRATCH_DEV=/dev/ubdc
SCRATCH_MNT=/mnt/scratch
RESULT_BASE=/host/results
RECREATE_TEST_DEV=true
MOUNT_PROG=/usr/local/bin/bbmount
UMOUNT_PROG=/usr/local/bin/bbumount
CFG
mkdir -p /mnt/test /mnt/scratch; chmod 777 /mnt/test /mnt/scratch
ARGS="$(cat /host/RUN_ARGS 2>/dev/null)"; [ -z "$ARGS" ] && ARGS="btrfs/001 generic/001"
mkfs.btrfs -f -q /dev/ubdb 2>/dev/null
echo "-- running: ./check $ARGS --"
./check $ARGS 2>&1 | tee /host/results/run.log | $BB grep -vE '^[[:space:]]*$'
echo "==== XFSTESTS DONE (uptime $($BB cut -d. -f1 /proc/uptime)s) ===="
sync
$BB poweroff -f 2>/dev/null; $BB halt -f
