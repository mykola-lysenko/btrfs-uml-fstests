#!/bin/bash
# prof-init.sh — like shard-init.sh but runs ONE test to completion with a high
# per-test timeout (1800s), so the profiler can measure true duration / pass-fail.
# The orchestrator's wall-clock cap is what distinguishes a real hang.
HOST_DIR=/home/prozak/uml-smoke

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HOME=/root TMPDIR=/tmp
BB=/usr/bin/busybox
$BB mount -t proc proc /proc
$BB mount -t sysfs sysfs /sys
$BB mount -t devtmpfs devtmpfs /dev 2>/dev/null
$BB ln -sf /proc/self/fd /dev/fd 2>/dev/null; $BB ln -sf /proc/self/fd/0 /dev/stdin 2>/dev/null; $BB ln -sf /proc/self/fd/1 /dev/stdout 2>/dev/null; $BB ln -sf /proc/self/fd/2 /dev/stderr 2>/dev/null
$BB mount -t tmpfs -o size=90% tmpfs /tmp
$BB mount -t tmpfs tmpfs /run 2>/dev/null
mkdir -p /dev/shm; $BB mount -t tmpfs tmpfs /dev/shm 2>/dev/null

SHARD=$($BB tr ' ' '\n' < /proc/cmdline | $BB sed -n 's/^shard=//p')
[ -z "$SHARD" ] && SHARD=0
$BB hostname "uml-prof-$SHARD"
# loopback up: src/locktest (generic/131,571,786,787) is a TCP client/server on lo
$BB ip link set lo up 2>/dev/null || $BB ifconfig lo 127.0.0.1 up 2>/dev/null
export TERM=linux
$BB mount -t hostfs -o "$HOST_DIR" none /host 2>/dev/null || echo "HOSTFS_FAIL"
SDIR="/host/shards/$SHARD"
mkdir -p "$SDIR/results"
echo "==== PROF $SHARD ($(uname -r)) ===="

cp -a /host/xfstests-built /tmp/xfstests
cd /tmp/xfstests
cat > local.config <<CFG
FSTYP=btrfs
TEST_DEV=/dev/ubdb
TEST_DIR=/mnt/test
SCRATCH_DEV=/dev/ubdc
SCRATCH_MNT=/mnt/scratch
RESULT_BASE=$SDIR/results
# util-linux mount works now (setuid-to-uid1000 trap fixed by stripping the bit)

CFG
mkdir -p /mnt/test /mnt/scratch; chmod 777 /mnt/test /mnt/scratch
ARGS="$($BB cat "$SDIR/RUN_ARGS" 2>/dev/null)"
if [ -z "$ARGS" ]; then echo "PROF $SHARD: empty RUN_ARGS"; else
  mkfs.btrfs -f -q /dev/ubdb >/dev/null 2>&1
  export FSTESTS_PER_TEST_TIMEOUT=1800
  T0=$($BB cut -d. -f1 /proc/uptime)
  ./check $ARGS >"$SDIR/results/run.log" 2>&1
  T1=$($BB cut -d. -f1 /proc/uptime)
  echo "PROF_DURATION=$((T1-T0))" > "$SDIR/results/duration"
fi
echo "==== PROF $SHARD DONE (uptime $($BB cut -d. -f1 /proc/uptime)s) ===="
sync
$BB poweroff -f 2>/dev/null; $BB halt -f
