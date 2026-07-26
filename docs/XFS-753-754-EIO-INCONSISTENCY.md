# generic/753 + generic/754 leave xfs inconsistent after EIO injection — CONFIRMED both platforms

**Status:** confirmed real (rig standards: two independent platforms,
deterministic), NOT yet root-caused, NOT yet reported upstream.
**Found:** 2026-07-25, immediately after the dm-sysfs harness fix — these
tests were invisible before it (their `_require` sysfs probes failed →
notrun in sweep #1; the sysfs-signature failure in sweep #2 masked the
real behavior).

## Result matrix

| platform | kernel | generic/753 | generic/754 |
|---|---|---|---|
| UML | xfs-for-next-0724 (56aa9ef3c413) | FAIL, solo-confirmed | FAIL, solo-confirmed |
| UML | for-next-0710 (7.1.0-rc7, vanilla xfs) | FAIL 2/2 | FAIL 2/2 |
| QEMU/KVM x86-64 | xfs-for-next-0724, same source via git archive | FAIL 3/3 | FAIL 3/3 |

Failing on vanilla 7.1 too → NOT a fresh xfs-for-next regression;
longstanding behavior (or longstanding test-expectation gap).

## Failure signatures (xfs_repair -n after the test)

- generic/753 (UML): `would clear attr fork`, `bad nblocks 4449 for inode
  132, would reset to 0`, `bad anextents 2275 for inode 132 ...` — attr
  fork damage across several inodes.
- generic/754 (KVM, identical 3/3): `bad hash table for directory inode
  128 (no data entry): would rebuild`.
- UML aggregate: `_check_xfs_filesystem: filesystem on /dev/ubdc is
  inconsistent (r)`.

Both tests configure the fs EIO error-handling knobs
(`error/metadata/EIO/max_retries`, `fail_at_unmount`) over dm-error and
inject failures; after unmount + log recovery the fs is left needing
repair. Console shows the expected `XFS (dm-0): metadata I/O error ...
error 5` + `log I/O error -5` storms while injection is active.

## Artifacts
- `results/qemu-753-754-xfs.out` — full 3-iteration KVM run
- `results/archive-20260725-100108/retry/results/generic/75{3,4}.*` — UML
  solo-confirmed artifacts

## Open questions before any upstream action
1. Read both tests' intent: is a repair-detectable residue arguably
   EXPECTED after forced EIO + shutdown, i.e. is this a test bug /
   known-caveat? (`_fixed_by_kernel_commit` tags, list archive.)
2. lore search for prior generic/753/754 reports (Anubis-blocked from the
   rig; do it from a browser).
3. If genuinely unreported: bisectable? It reproduces on 7.1 vanilla, so
   the bisect range is old; first check when the tests entered xfstests
   and whether they EVER passed on any kernel (a never-passing test
   usually means test-expectation questions, ask on fstests list first).

## QEMU-path fixes made along the way (now in repo)
- qemu-init: `DM_DISABLE_UDEV=1` (dm tests hung waiting on udev cookies),
  per-fstyp mkfs (`mkfs.xfs -fq`), SCRATCH_DEV_POOL only for btrfs.
- build-x86.sh: `EXTRA_KCONFIG` env for per-fs config sets.
- build-qemu-rootfs.sh: codified image build (the ad hoc July image
  carried an April xfstests inside rootfs-xfs/opt — silently stale; the
  stale copy is deleted and staging now always overlays fresh
  xfstests-built).
