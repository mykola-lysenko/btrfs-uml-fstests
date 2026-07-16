# Multi-fs expansion: xfs now, fuse2fs next

Decision 2026-07-16 (user): xfs first, then fuse via **fuse2fs** (ext4-via-
fuse from e2fsprogs — real mkfs/scratch semantics, and it's what upstream
fuse fstests work targets). Both AFTER the T6 same-kernel A/B rerun.

## Phase 1: xfs

Already in place:
- rootfs has full xfsprogs (mkfs.xfs, xfs_repair, xfs_scrub, xfs_db, ...)
  and mkfs.ext4 — nothing to install.
- shard-init.sh now takes `fstyp=` from the kernel cmdline (default btrfs):
  sets FSTYP in local.config, plain SCRATCH_DEV for non-btrfs (pool is
  btrfs-only), mkfs.$FSTYP on the test dev. NOT yet deployed to
  ~/uml-smoke/rootfs-xfs/ — deploy is `cp` + `chmod +x` once the rig is
  idle (the probe boots read it live).

To do, in order:
1. Kernel: enable in the UML .config and rebuild (do NOT build while a
   timing-sensitive run is on the host):
       CONFIG_XFS_FS=y CONFIG_XFS_QUOTA=y CONFIG_XFS_POSIX_ACL=y
       CONFIG_XFS_RT=y CONFIG_XFS_ONLINE_SCRUB=y CONFIG_XFS_ONLINE_REPAIR=y
       CONFIG_XFS_DEBUG=y   # asserts + error-injection knobs many tests use
   (+ CONFIG_FUSE_FS=y in the same rebuild to save a cycle for phase 2)
2. Deploy shard-init.sh; smoke: boot one guest fstyp=xfs with a handful of
   known-fast generic tests + xfs/001-ish; confirm FSTYP/SCRATCH wiring.
3. First full run: generic + xfs groups, fstyp=xfs on the standard 14+2
   geometry. times-db is btrfs-timed — acceptable first approximation for
   LPT; record xfs times into a separate times-db-xfs.txt for reslicing.
4. Triage the fresh failure pile with the established discipline
   (solo-retry classifier, QEMU cross-check for anything interesting;
   remember the third-strike lesson: 0/N on KVM ≠ artifact — find the
   timing lever before writing anything off).
5. Later, optional: external log/rt devices (USE_EXTERNAL, SCRATCH_LOGDEV
   from a pool img) to unlock the log/rt groups.

## Phase 2: fuse2fs

1. Kernel: CONFIG_FUSE_FS=y (folded into step 1 above).
2. rootfs: /dev/fuse via devtmpfs should appear automatically once the
   module is =y (no udev needed — verify); build/install fuse2fs +
   libfuse into rootfs.
3. xfstests FSTYP=fuse mounts `-t fuse$FUSE_SUBTYP` and treats the fs as
   uncheckable (no fsck, many _notrun). Expect a few hundred runnable
   generic tests. Wiring: FSTYP=fuse + FUSE_SUBTYP=.fuse2fs-style setup;
   scratch mkfs = mke2fs on the backing dev; may need a small wrapper so
   _scratch_mkfs works — investigate xfstests' fuse expectations
   (common/config:363,538; common/rc:434,3681) at implementation time.
4. Value niche: kernel fuse layer is under active development (io_uring
   passthrough etc.); mass-parallel cheap UML guests each carrying its own
   userspace server is an uncrowded coverage angle.

## Cost estimates (from 2026-07-16 assessment)
- xfs: ~half a day to first full run; a few evenings of triage to a
  certified baseline (~800 xfs tests, largest per-fs suite).
- fuse2fs: 1-2 days to runnable; triage story less charted.
