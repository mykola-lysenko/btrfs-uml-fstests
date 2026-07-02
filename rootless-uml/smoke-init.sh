#!/bin/busybox sh
# smoke-init.sh — UML guest init: btrfs smoke test + feature-coverage probe.
#
# Boots in seconds. Proves the core loop (mkfs/mount/subvol/snapshot/check) and
# probes what btrfs features actually work in UML. Findings (see
# docs/SMOKE-TEST-FINDINGS.md): single-dev, compression (zlib/lzo/zstd), multi-
# device RAID1/RAID10, device add/remove, quota, scrub, balance, and device-mapper
# (dm-flakey/dm-log-writes) ALL work in UML — contradicting the repo README's
# claim that multi-device and dm-flakey tests are UML-incompatible.
#
# Needs a minimal rootfs: busybox + btrfs-progs + dmsetup (+ their lib closure).
# Boot with 4 ubd devices for the multi-device probes:
#   ./linux initrd=initramfs.cpio.gz ubda=d0 ubdb=d1 ubdc=d2 ubdd=d3 \
#           mem=1500M rdinit=/init con0=fd:0,fd:1 con=null
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
/bin/busybox --install -s /bin 2>/dev/null
mount -t proc proc /proc; mount -t sysfs sysfs /sys; mount -t devtmpfs devtmpfs /dev 2>/dev/null
mkdir -p /mnt/t
P(){ printf "PROBE %-22s " "$1"; shift; "$@" >/tmp/o 2>&1 && echo PASS || echo FAIL; }
echo "==== UML BTRFS SMOKE + FEATURE PROBE ($(uname -r)) ===="
[ -e /dev/mapper/control ] && echo "DM: present" || echo "DM: absent"

P mkfs.single   mkfs.btrfs -f -q /dev/ubda
P mount.single  mount /dev/ubda /mnt/t
P subvol        btrfs subvolume create /mnt/t/sv
P snapshot      btrfs subvolume snapshot /mnt/t/sv /mnt/t/snap
P quota.enable  btrfs quota enable /mnt/t
P scrub         btrfs scrub start -B /mnt/t
P balance       btrfs balance start --full-balance /mnt/t
umount /mnt/t
for c in zlib lzo zstd; do
  mount -o compress=$c /dev/ubda /mnt/t 2>/tmp/o \
    && { dd if=/dev/zero of=/mnt/t/z bs=1M count=8 2>/dev/null; sync; echo "PROBE compress=$c            PASS"; umount /mnt/t; } \
    || echo "PROBE compress=$c            FAIL"
done

# Multi-device (repo claims impossible in UML — it isn't)
P mkfs.raid1  mkfs.btrfs -f -q -d raid1  -m raid1  /dev/ubda /dev/ubdb
P mkfs.raid10 mkfs.btrfs -f -q -d raid10 -m raid10 /dev/ubda /dev/ubdb /dev/ubdc /dev/ubdd
P mount.raid10 mount /dev/ubda /mnt/t; umount /mnt/t 2>/dev/null

# dm-flakey (crash-consistency infra — repo excludes it, but the kernel target works)
if [ -e /dev/mapper/control ]; then
  SECT=$(blockdev --getsz /dev/ubda)
  if dmsetup create fl --table "0 $SECT flakey /dev/ubda 0 60 0" 2>/tmp/o; then
    dmsetup mknodes
    P mkfs.on_flakey  mkfs.btrfs -f -q /dev/mapper/fl
    P mount.on_flakey mount /dev/mapper/fl /mnt/t
    umount /mnt/t 2>/dev/null; dmsetup remove fl
  fi
  echo "dm targets: $(dmsetup targets 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"
fi
echo "==== PROBE DONE (uptime $(cut -d. -f1 /proc/uptime)s) ===="
poweroff -f 2>/dev/null; halt -f
