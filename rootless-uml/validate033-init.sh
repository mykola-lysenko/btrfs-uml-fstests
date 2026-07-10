#!/bin/bash
# Validate the btrfs/033 rewrite: does batching 4K backwards writes into ONE
# xfs_io produce the SAME fragmentation as the original per-write fork loop?
HOST_DIR=/home/prozak/uml-smoke
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HOME=/root TMPDIR=/tmp
BB=/usr/bin/busybox
$BB mount -t proc proc /proc; $BB mount -t sysfs sysfs /sys
$BB mount -t devtmpfs devtmpfs /dev 2>/dev/null
$BB ln -sf /proc/self/fd /dev/fd 2>/dev/null
$BB mount -t tmpfs -o size=90% tmpfs /tmp
$BB mount -t hostfs -o "$HOST_DIR" none /host 2>/dev/null
cp -a /host/xfstests-built /tmp/x; cd /tmp/x
XFS_IO=/usr/local/bin/xfs_io; [ -x $XFS_IO ] || XFS_IO=$(command -v xfs_io)
BB2=/usr/local/bin/btrfs
N=${N:-2048}
OUT=/host/shards/val033
mkdir -p $OUT
echo "==== VALIDATE btrfs/033 rewrite (N=$N writes) ====" | tee $OUT/report
/usr/local/bin/bbmount >/dev/null 2>&1
mkfs.btrfs -f -q /dev/ubdc >/dev/null 2>&1
mkdir -p /mnt/s; /usr/local/bin/bbmount /dev/ubdc /mnt/s 2>/dev/null || mount /dev/ubdc /mnt/s

# --- method A: original per-write fork loop ---
touch /mnt/s/fooA
TA0=$($BB cut -d. -f1 /proc/uptime)
i=$N
while [ $i -ge 1 ]; do
  $XFS_IO -f -d -c "pwrite $((i*4096)) 4096" /mnt/s/fooA >/dev/null 2>&1
  i=$((i-1))
done
TA1=$($BB cut -d. -f1 /proc/uptime)

# --- method B: batched single xfs_io ---
touch /mnt/s/fooB
TB0=$($BB cut -d. -f1 /proc/uptime)
i=$N; { while [ $i -ge 1 ]; do echo "pwrite $((i*4096)) 4096"; i=$((i-1)); done; } \
  | $XFS_IO -f -d /mnt/s/fooB >/dev/null 2>&1
TB1=$($BB cut -d. -f1 /proc/uptime)

sync
# extent counts via fiemap
EA=$($XFS_IO -c fiemap /mnt/s/fooA 2>/dev/null | $BB grep -c ':')
EB=$($XFS_IO -c fiemap /mnt/s/fooB 2>/dev/null | $BB grep -c ':')
SA=$($BB stat -c %s /mnt/s/fooA); SB=$($BB stat -c %s /mnt/s/fooB)
{
echo "method A (fork loop):   forks=$N  time=$((TA1-TA0))s  size=$SA  fiemap_extents=$EA"
echo "method B (batched):     forks=1   time=$((TB1-TB0))s  size=$SB  fiemap_extents=$EB"
echo "same_size=$([ "$SA" = "$SB" ] && echo YES || echo NO)  same_extent_count=$([ "$EA" = "$EB" ] && echo YES || echo NO)"
} | tee -a $OUT/report
sync
$BB poweroff -f 2>/dev/null; $BB halt -f
