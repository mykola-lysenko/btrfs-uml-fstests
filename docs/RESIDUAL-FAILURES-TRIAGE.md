# Triage of the 12 residual failures

From the definitive run (btrfs `for-next` 7.1.0-rc7, memory-safe 8×1400M). These
are the genuine output mismatches after removing the slow-tier (timeouts) and the
hangs/crashes (which were memory overcommit).

**Bottom line: none are btrfs kernel regressions.** All 12 are artifacts of the
rootless-UML environment or userspace tooling. They split into *fixable* (would
fold back into the core) and *inherent UML limitations* (stay excluded).

| test | symptom | category | verdict |
|------|---------|----------|---------|
| btrfs/058 | `Cannot read termcap database` | missing terminfo | **fixable** — add `ncurses-base` to rootfs |
| generic/042 | `can't setup loop device` | UML has no `/dev/loop` | **fixable/skip** — enable loop + nodes, or should `_notrun` |
| generic/131 | `Client reported failure (1)` (lockfile) | lock-helper | **investigate** — lock/lease helper under UML |
| generic/571 | `Client reported failure (1)` (lease) | lock-helper | **investigate** |
| generic/786 | `Client reported failure (1)` (locks) | lock-helper | **investigate** |
| generic/787 | `Client reported failure (1)` (locks) | lock-helper | **investigate** |
| btrfs/289 | `Unknown global option: -l` | btrfs-progs v7.0 | tooling — progs option mismatch |
| btrfs/295 | `Unknown global option: -l` + dev mounted | btrfs-progs v7.0 | tooling — progs + stale mount |
| btrfs/089 | `mount: must be superuser` (nested subvol) | util-linux mount EPERM | **inherent** UML mount limitation |
| generic/306 | `mount: must be superuser` (bind) | util-linux mount EPERM | **inherent** |
| btrfs/330 | `mount: invalid option -- 'V'` | busybox mount lacks `-V` | **inherent** busybox-mount |
| generic/050 | mount message diff (read-only) | busybox mount cosmetic | **inherent** busybox-mount |

## Buckets

- **Mount limitations (4):** btrfs/089, generic/306 (util-linux `mount` EPERMs under
  UML even as root), btrfs/330, generic/050 (busybox `mount` lacks options/messages).
  Fundamental to the rootless setup — keep excluded.
- **Locking helper (4):** generic/131, 571, 786, 787 all fail their client/server
  lock/lease helper uniformly. Not btrfs-specific (VFS locking). Worth one focused
  look — could be a fixable helper/setup issue or a real UML file-locking gap.
- **btrfs-progs (2):** btrfs/289, 295 hit `Unknown global option: -l` from progs v7.0
  — a userspace/test version mismatch, not a kernel bug.
- **Trivially fixable (2):** btrfs/058 (add `ncurses-base` for terminfo),
  generic/042 (loop-device support or a proper `_notrun`).

## Next
Quick wins: add `ncurses-base` (btrfs/058) and sort out loop-device/`_notrun`
(generic/042). Then investigate the 4 lock/lease tests together (shared root cause).
The mount and progs classes are accepted environment limitations.
