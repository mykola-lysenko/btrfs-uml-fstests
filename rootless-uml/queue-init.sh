#!/bin/bash
# queue-init.sh — UML guest PID1 for a queue-fed xfstests lane.
#
# Instead of a fixed RUN_ARGS slice, the guest claims tests from a shared
# hostfs queue by atomic rename (mv): /host/queue/q (slim work) and
# /host/queue/qbig (fat work). qrole=fat lanes drain qbig first, then help q.
# Claim markers live in /host/queue/claimed/<item>.<shard> and move to
# /host/queue/done/ after the batch completes, so the supervisor can requeue
# exactly the claimed-but-unfinished tests of a dead lane.
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

SHARD=$($BB tr ' ' '\n' < /proc/cmdline | $BB sed -n 's/^shard=//p'); [ -z "$SHARD" ] && SHARD=0
ROLE=$($BB tr ' ' '\n' < /proc/cmdline | $BB sed -n 's/^qrole=//p'); [ -z "$ROLE" ] && ROLE=slim
$BB hostname "uml-q$SHARD"
# loopback up: src/locktest (generic/131,571,786,787) is a TCP client/server on lo
$BB ip link set lo up 2>/dev/null || $BB ifconfig lo 127.0.0.1 up 2>/dev/null
export TERM=linux
$BB mount -t hostfs -o "$HOST_DIR" none /host 2>/dev/null || echo "HOSTFS_FAIL"
SDIR="/host/shards/$SHARD"; QR=/host/queue
mkdir -p "$SDIR/results"
echo "==== LANE $SHARD role=$ROLE ($(uname -r)) ===="

cp -a /host/xfstests-built /tmp/xfstests
cd /tmp/xfstests
cat > local.config <<CFG
FSTYP=btrfs
TEST_DEV=/dev/ubdb
TEST_DIR=/mnt/test
SCRATCH_MNT=/mnt/scratch
RESULT_BASE=$SDIR/results
CFG
if [ -b /dev/ubdg ]; then
  echo 'SCRATCH_DEV_POOL="/dev/ubdc /dev/ubdd /dev/ubde /dev/ubdf /dev/ubdg"' >> local.config
  [ -b /dev/ubdh ] && echo 'LOGWRITES_DEV=/dev/ubdh' >> local.config
else
  echo 'SCRATCH_DEV=/dev/ubdc' >> local.config
fi
mkdir -p /mnt/test /mnt/scratch; chmod 777 /mnt/test /mnt/scratch
mkfs.btrfs -f -q /dev/ubdb >/dev/null 2>&1
export FSTESTS_PER_TEST_TIMEOUT=900
# no udev in this rootfs: libdevmapper must create /dev/mapper nodes itself
export DM_DISABLE_UDEV=1

# claim one item from queue subdir $1; prints the TEST NAME, remembers marker
CLAIMED=""
claim(){
  local sub=$1 f
  for f in $($BB ls "$QR/$sub" 2>/dev/null | $BB head -6); do
    if $BB mv "$QR/$sub/$f" "$QR/claimed/$f.$SHARD" 2>/dev/null; then
      CLAIMED="$CLAIMED $f.$SHARD"
      $BB cat "$QR/claimed/$f.$SHARD"
      return 0
    fi
  done
  return 1
}
next(){ # role-aware: fat drains qbig first, then helps q; slim only q
  if [ "$ROLE" = fat ]; then claim qbig && return 0; fi
  claim q
}

while :; do
  batch=""; CLAIMED=""
  for i in 1 2 3; do
    t=$(next) || break
    batch="$batch $t"
  done
  [ -z "$batch" ] && break
  ./check $batch >> "$SDIR/results/run.log" 2>&1
  for m in $CLAIMED; do $BB mv "$QR/claimed/$m" "$QR/done/$m" 2>/dev/null; done
done
echo "==== LANE $SHARD DONE (uptime $($BB cut -d. -f1 /proc/uptime)s) ===="
sync
$BB poweroff -f 2>/dev/null; $BB halt -f
