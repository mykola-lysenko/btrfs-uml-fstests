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
# fstyp=btrfs|xfs|ext4 on the kernel cmdline picks the fs under test
FSTYP=$($BB tr ' ' '\n' < /proc/cmdline | $BB sed -n 's/^fstyp=//p'); [ -z "$FSTYP" ] && FSTYP=btrfs
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
FSTYP=$FSTYP
TEST_DEV=/dev/ubdb
TEST_DIR=/mnt/test
SCRATCH_MNT=/mnt/scratch
RESULT_BASE=$SDIR/results
CFG
# Only btrfs consumes a scratch pool; other fs get a plain SCRATCH_DEV.
if [ "$FSTYP" = btrfs ] && [ -b /dev/ubdg ]; then
  echo 'SCRATCH_DEV_POOL="/dev/ubdc /dev/ubdd /dev/ubde /dev/ubdf /dev/ubdg"' >> local.config
  [ -b /dev/ubdh ] && echo 'LOGWRITES_DEV=/dev/ubdh' >> local.config
else
  [ -b /dev/ubdh ] && echo 'LOGWRITES_DEV=/dev/ubdh' >> local.config
  echo 'SCRATCH_DEV=/dev/ubdc' >> local.config
fi
# fuse mode = fuse2fs over ext4-formatted ubd devices (see
# patches-xfstests/fuse2fs-mkfs-and-fsck.patch for the harness side)
[ "$FSTYP" = fuse ] && echo 'FUSE_SUBTYP=.fuse2fs' >> local.config
# /mnt lives on the hostfs root SHARED by all guests: cover it with a
# per-guest tmpfs. Kernel fs never noticed the shared debris; libfuse2
# refuses non-empty mountpoints, so one guest's leak broke every lane.
$BB mount -t tmpfs tmpfs /mnt
mkdir -p /mnt/test /mnt/scratch; chmod 777 /mnt/test /mnt/scratch
case "$FSTYP" in
  ext4) mkfs.ext4 -Fq /dev/ubdb >/dev/null 2>&1 ;;
  fuse) mkfs.ext4 -Fq -O ^has_journal /dev/ubdb >/dev/null 2>&1
        mkfs.ext4 -Fq -O ^has_journal /dev/ubdc >/dev/null 2>&1 ;;
  *)    mkfs.$FSTYP -f -q /dev/ubdb >/dev/null 2>&1 ;;
esac
# 1300 (was 900): T3 lesson — at 16 lanes the longest healthy tests cross
# 900s and die as exit-124. Keep the supervisor invariant STALL > this.
export FSTESTS_PER_TEST_TIMEOUT=1300
# no udev in this rootfs: libdevmapper must create /dev/mapper nodes itself
export DM_DISABLE_UDEV=1

# claim one item from queue subdir $1; prints the MARKER NAME. The caller
# runs claim() in a command substitution, so any variable set here is lost
# in the subshell — the marker must travel via stdout, not via globals
# (the original CLAIMED accumulator silently never reached the parent and
# markers were stranded in claimed/ forever).
claim(){
  local sub=$1 f
  for f in $($BB ls "$QR/$sub" 2>/dev/null | $BB head -6); do
    if $BB mv "$QR/$sub/$f" "$QR/claimed/$f.$SHARD" 2>/dev/null; then
      echo "$f.$SHARD"
      return 0
    fi
  done
  return 1
}
next(){ # role-aware: fat drains qbig first, then helps q; slim only q
  if [ "$ROLE" = fat ]; then claim qbig && return 0; fi
  claim q
}

# Sick-lane guard: a ./check that exits without appending ANY output is a
# broken environment (dead mount, wiped tree, ...). One silent batch could
# be a fluke; two in a row means every further claim would be silently
# destroyed — put the claims back and die loudly instead. (Both fuse
# sweep collapses drained the whole queue through exactly this hole.)
silent=0
while :; do
  batch=""; markers=""
  for i in 1 2 3; do
    m=$(next) || break
    markers="$markers $m"
    batch="$batch $($BB cat "$QR/claimed/$m")"
  done
  [ -z "$markers" ] && break
  lines_before=$($BB grep -c '^generic\|^btrfs\|^xfs\|^ext4' "$SDIR/results/run.log" 2>/dev/null || echo 0)
  ./check $batch >> "$SDIR/results/run.log" 2>&1
  rc=$?
  lines_after=$($BB grep -c '^generic\|^btrfs\|^xfs\|^ext4' "$SDIR/results/run.log" 2>/dev/null || echo 0)
  echo "$($BB date +%s) rc=$rc dverdicts=$((lines_after-lines_before)) batch:$batch" >> "$SDIR/results/batches.log"
  if [ "$lines_after" = "$lines_before" ]; then
    # silent batch: never destroy the claims — put them back
    silent=$((silent+1))
    for m in $markers; do
      base=${m%.$SHARD}
      $BB mv "$QR/claimed/$m" "$QR/q/$base" 2>/dev/null
    done
    if [ "$silent" -ge 2 ]; then
      echo "==== LANE $SHARD SICK: ./check silent twice (rc=$rc), claims requeued ===="
      break
    fi
    continue
  fi
  silent=0
  for m in $markers; do $BB mv "$QR/claimed/$m" "$QR/done/$m" 2>/dev/null; done
done
echo "==== LANE $SHARD DONE (uptime $($BB cut -d. -f1 /proc/uptime)s) ===="
sync
$BB poweroff -f 2>/dev/null; $BB halt -f
