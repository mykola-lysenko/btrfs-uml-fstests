# Firsthand runbook: observe the raid5 scrub bug (0002/v2) yourself

Goal: before sending v2, run the failing test with your own hands, read
the evidence files, and watch the parity bytes on disk before/after a
scrub — on both the buggy and the fixed kernel.

Two kernel binaries, same tree (for-next-0710), differ ONLY in the fix:
- BUGGY  : ~/uml-smoke/linux-for-next-0710/linux.xfs-sweep-baseline
- FIXED  : ~/uml-smoke/linux-for-next-0710/linux   (v2 remove+ASSERT)

## Step 1 — watch it fail (5 min, batch)
    cd ~/uml-smoke
    bash ~/sources/btrfs-uml-fstests/rootless-uml/probe-297.sh \
        ~/uml-smoke/linux-for-next-0710/linux.xfs-sweep-baseline buggy 8
Expect intermittent FAILs (historically up to 7/8 under UML timing —
each iteration is a fresh boot, so page-allocator state varies).

## Step 2 — read the evidence of a failed iteration
    ls ~/uml-smoke/results/297-buggy-iter*
- `*.out.bad`  — the golden diff: the test's own verification finds the
  parity stripe still holding the injected garbage after a scrub that
  reported zero errors.
- `*.parity`   — the "first 16 bytes" instrumentation grep from
  297.full: what the kernel THOUGHT was on disk. On the buggy kernel
  this never matches the device (stale 0xaa / zeroed pages instead of
  the injected 0xff) because scrub_assemble_read_bios() submitted no
  reads at all.

## Step 3 — same command, fixed kernel
    bash ~/sources/btrfs-uml-fstests/rootless-uml/probe-297.sh \
        ~/uml-smoke/linux-for-next-0710/linux buggy-vs-v2 8
Expect 8/8 PASS.

## Step 4 — fully manual: bytes on disk, before and after scrub
Boot an interactive guest (run this in YOUR terminal — it takes over
stdin/stdout; type `halt -f` or Ctrl-C the process to leave):

    cd ~/uml-smoke && d=shards/manual && rm -rf $d && mkdir -p $d && \
    truncate -s 64M $d/a.img && truncate -s 3G $d/b.img $d/c.img $d/e.img && \
    ./linux-for-next-0710/linux.xfs-sweep-baseline rootfstype=hostfs \
      rootflags=$HOME/uml-smoke/rootfs-xfs rw init=/bin/bash umid=manual \
      ubda=$d/a.img ubdb=$d/b.img ubdc=$d/c.img ubdd=$d/e.img \
      seccomp=on mem=2000M con0=fd:0,fd:1 con=null

Inside the guest shell, paste this prelude once:

    export PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root
    busybox mount -t proc proc /proc; busybox mount -t sysfs sysfs /sys
    busybox mount -t devtmpfs devtmpfs /dev; busybox mount -t tmpfs tmpfs /tmp
    busybox mount -t tmpfs tmpfs /mnt; mkdir -p /mnt/s

Now the experiment (mirrors what btrfs/297 automates):

    mkfs.btrfs -f -d raid5 -m raid1 /dev/ubdc /dev/ubdd
    mount /dev/ubdc /mnt/s
    # one full 64K stripe of known data
    xfs_io -f -c "pwrite -S 0xab 0 64k" /mnt/s/f
    sync
    # find where data and parity physically live
    LOG=$(btrfs inspect-internal dump-tree -t extent /dev/ubdc | \
          sed -n 's/.*(\([0-9]*\) EXTENT_ITEM.*/\1/p' | tail -1)
    btrfs inspect-internal map-swarm 2>/dev/null || \
      btrfs-map-logical -l $LOG /dev/ubdc     # shows mirror/parity offsets
    # read the parity bytes (device+offset from map output), e.g.:
    #   od -A x -t x1 -j <PHYS> -N 16 /dev/ubdd
    # corrupt them:
    #   xfs_io -f -d -c "pwrite -S 0xff <PHYS> 4096" /dev/ubdd
    # scrub and observe:
    btrfs scrub start -B /mnt/s          # note: 0 errors reported either way
    #   od -A x -t x1 -j <PHYS> -N 16 /dev/ubdd
    # BUGGY kernel: bytes intermittently STILL 0xff (unrepaired) while
    #   scrub said zero errors. FIXED kernel: always back to real parity.

(If btrfs-map-logical output is confusing, `cat /tmp/xfstests` isn't
available in this bare shell — the mapping one-liners in the test file
itself are at ~/uml-smoke/xfstests-built/tests/btrfs/297 on the host.)

## Sending v2 (after Step 1-3 satisfy you)
1. Get the v1 Message-ID: in Gmail open the sent v1 mail -> "Show
   original" -> copy the Message-ID header (with angle brackets).
2. Put it into the `v1:` lore link in
   upstream-kernel/0002-btrfs-raid56-fix-scrub-read-assembly-v2.patch
   (replace [MSGID-TODO] with the id, no brackets, in the URL).
3. Send as a reply to the thread:
    git send-email \
      --to=linux-btrfs@vger.kernel.org \
      --cc=quwenruo.btrfs@gmx.com --cc=wqu@suse.com \
      --cc=clm@fb.com --cc=josef@toxicpanda.com --cc=dsterba@suse.com \
      --cc=linux-kernel@vger.kernel.org --cc=stable@vger.kernel.org \
      --in-reply-to='<MESSAGE-ID-WITH-BRACKETS>' \
      upstream-kernel/0002-btrfs-raid56-fix-scrub-read-assembly-v2.patch
