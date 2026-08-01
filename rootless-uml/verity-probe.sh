#!/bin/bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HOME=/root TMPDIR=/tmp TERM=linux
BB=/usr/bin/busybox
$BB mount -t proc proc /proc; $BB mount -t sysfs sysfs /sys
$BB mount -t devtmpfs devtmpfs /dev 2>/dev/null
$BB mount -t tmpfs -o size=50% tmpfs /tmp; $BB mount -t tmpfs tmpfs /mnt; mkdir -p /mnt/s
echo "=== VERITY-PROBE: $(uname -r) ==="
mkfs.btrfs -f -q /dev/ubdc && mount /dev/ubdc /mnt/s || { echo SETUP-FAIL; $BB poweroff -f; }
cycle(){ umount /mnt/s && mount /dev/ubdc /mnt/s; }
report(){ echo "$1: size=$(stat -c%s $2 2>&1)"; }
dd if=/dev/zero of=/mnt/s/f1 bs=1 count=0 seek=200000 status=none
report "after-truncate(live)" /mnt/s/f1
sync; cycle
report "after-cycle" /mnt/s/f1
cp /mnt/s/f1 /mnt/s/f2
report "after-cp(live)" /mnt/s/f2
sync; cycle
report "cp-after-cycle" /mnt/s/f2
fsverity enable --block-size=4096 /mnt/s/f2 2>&1 | head -2
report "after-verity(live)" /mnt/s/f2
cycle
report "verity-after-cycle" /mnt/s/f2
echo "open test:"; cat /mnt/s/f2 > /dev/null 2>&1 && echo "OPEN+READ OK" || echo "OPEN/READ FAILED errno=$?"
dmesg | grep -iE "btrfs.*(error|verity)" | tail -3
umount /mnt/s; $BB poweroff -f
