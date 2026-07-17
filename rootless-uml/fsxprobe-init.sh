#!/bin/bash
# fsxprobe-init.sh — A/B probe for the fuse2fs zero-range EINVAL (generic/363,
# 521, 522). Same guest, same kernel: ubdb mounted via fuse2fs, ubdc via the
# KERNEL ext4 driver. Minimal candidate sequence from the fsx op logs:
#   falloc keep-size past EOF -> truncate up -> zero-range over the hole
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HOME=/root TMPDIR=/tmp
BB=/usr/bin/busybox
$BB mount -t proc proc /proc; $BB mount -t sysfs sysfs /sys
$BB mount -t devtmpfs devtmpfs /dev 2>/dev/null
$BB mount -t tmpfs -o size=90% tmpfs /tmp
$BB mount -t tmpfs tmpfs /mnt
HOST_DIR=/home/prozak/uml-smoke
$BB mount -t hostfs -o "$HOST_DIR" none /host 2>/dev/null
mkdir -p /mnt/fuse /mnt/kern
echo "==== FSXPROBE ($(uname -r)) ===="

mkfs.ext4 -Fq /dev/ubdb; mkfs.ext4 -Fq /dev/ubdc
mount -t fuse.fuse2fs /dev/ubdb /mnt/fuse || echo "FUSE MOUNT FAILED"
mount -t ext4 /dev/ubdc /mnt/kern       || echo "KERNEL MOUNT FAILED"

probe(){ # $1=label $2=dir
  local f=$2/probe
  rm -f $f
  echo "--- $1: full sequence (falloc -k, truncate, fzero) ---"
  xfs_io -f -c "falloc -k 0x4c903 0x9aa4" -c "truncate 0x6c000" \
         -c "fzero 0x26ec3 0x13f78" $f 2>&1
  echo "rc=$?"
  rm -f $f
  echo "--- $1: no-falloc variant (truncate, fzero) ---"
  xfs_io -f -c "truncate 0x6c000" -c "fzero 0x26ec3 0x13f78" $f 2>&1
  echo "rc=$?"
  rm -f $f
  echo "--- $1: fzero alone on empty file ---"
  xfs_io -f -c "truncate 0x40000" -c "fzero 0x1000 0x2000" $f 2>&1
  echo "rc=$?"
}
probe FUSE2FS /mnt/fuse
probe KERNEL-EXT4 /mnt/kern

# full fsx replay of the generic/363 op log on both mounts
cp -a /host/xfstests-built /tmp/xfstests
FSX=/tmp/xfstests/ltp/fsx
if [ -x $FSX ] && [ -f /host/shards/.fsxops ]; then
  for m in fuse:/mnt/fuse kern:/mnt/kern; do
    lbl=${m%%:*}; dir=${m##*:}
    echo "--- fsx replay on $lbl ---"
    $FSX -q --replay-ops /host/shards/.fsxops $dir/junk 2>&1 | head -8
    echo "replay rc=$?"
    rm -f $dir/junk*
  done
fi
echo "==== FSXPROBE DONE ===="
sync; $BB poweroff -f 2>/dev/null; $BB halt -f
