#!/bin/bash
# manual-parity.sh — boot-to-ready guest for the BYTE-LEVEL raid5 scrub
# experiment (runbook step 4). Mirrors what btrfs/297 automates; you drive
# each phase with one-word commands: s1 s2 s3 s4 s5 s6 (in order).
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HOME=/root TMPDIR=/tmp TERM=linux
BB=/usr/bin/busybox
$BB mount -t proc proc /proc; $BB mount -t sysfs sysfs /sys
$BB mount -t devtmpfs devtmpfs /dev 2>/dev/null
$BB mount -t tmpfs -o size=90% tmpfs /tmp
$BB mount -t tmpfs tmpfs /mnt; mkdir -p /mnt/s

cat > /root/.parityrc <<'RC'
M=/mnt/s
s1(){ # mkfs 2-device raid5 (data) and mount
  mkfs.btrfs -f -d raid5 -m single /dev/ubdc /dev/ubdd | grep -E 'Devices|RAID'
  mount -o space_cache=v2 /dev/ubdc $M && echo "mounted at $M"
}
s2(){ # one full 64K data stripe of 0xaa, O_DIRECT like the test
  xfs_io -f -d -c "pwrite -S 0xaa -b 64K 0 64K" $M/foobar >/dev/null
  sync && echo "wrote 64K of 0xaa to $M/foobar"
}
s3(){ # resolve where data and parity live physically
  LOG=$(filefrag -v $M/foobar | awk '$1=="0:" {gsub(/\.\./,"",$4); print $4*4096; exit}')
  echo "btrfs logical address of extent: $LOG"
  btrfs-map-logical -l $LOG /dev/ubdc
  read -r PHYS DEV <<<"$(btrfs-map-logical -l $LOG /dev/ubdc | awk '$1=="mirror" && $2=="2" {print $6, $8; exit}')"
  echo ">>> P stripe: device $DEV physical $PHYS  (mirror 2 == parity on raid5)"
  echo ">>> parity bytes now (expect aa — on 2-dev raid5, parity == data):"
  xfs_io -c "pread -qv $PHYS 16" $DEV
}
s4(){ # corrupt parity ON THE DEVICE, fs unmounted so nothing interferes
  umount $M
  xfs_io -d -c "pwrite -S 0xff -b 64K $PHYS 64K" $DEV >/dev/null
  echo ">>> parity bytes after corruption (expect ff):"
  xfs_io -c "pread -qv $PHYS 16" $DEV
}
s5(){ # scrub — the moment of truth
  mount -o space_cache=v2 /dev/ubdc $M
  btrfs scrub start -BdR $M
  umount $M
  echo ">>> note: error counters above are 0 either way (no P/Q counter by design)"
}
s6(){ # what is REALLY on the device now?
  echo ">>> parity bytes after scrub:"
  xfs_io -c "pread -qv $PHYS 16" $DEV
  echo ">>> aa = scrub read+recomputed+repaired (FIXED kernel, always)"
  echo ">>> ff = scrub submitted no reads and left corruption (BUGGY kernel, intermittent)"
  echo ">>> rerun cycle: umount $M 2>/dev/null; then s1 s2 s3 s4 s5 s6 again"
}
RC
echo ""
echo "=== parity lab ready. Run in order: s1 s2 s3 s4 s5 s6 ==="
echo "=== each function is ~5 lines: cat /root/.parityrc to read them ==="
echo "=== leave with: halt -f ==="
exec bash --rcfile /root/.parityrc -i
