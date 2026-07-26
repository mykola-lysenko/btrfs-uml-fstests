# generic/753 + generic/754 "inconsistency" — RESOLVED: stale xfs_repair, not a kernel bug

**Status:** RESOLVED 2026-07-25, same day. NOT a kernel bug — the
"corruption" was manufactured by xfs_repair 6.6.0 (Ubuntu pool, ~18
months older than the kernels under test). Decisive experiment: the SAME
post-generic/753 scratch image judged by both repair versions —
xfs_repair 6.6.0: exit 1, "would clear attr fork / bad nblocks";
xfs_repair 7.1.1: exit 0, CLEAN (the `XFS_ATTR_INCOMPLETE` entries are
legitimate post-crash residue, noted as informational). generic/754's
test header even documents the repair-side fix ("xfs_repair: small
remote symlinks are ok") as not-yet-released at snapshot time; xfs/136's
xfs_db output drift is the same stale-progs root cause. Kernel log
recovery does its job on both 7.1 and xfs-for-next.
Fix: xfsprogs pinned + built from source (build-xfsprogs.sh, PINS
XFSPROGS_VER=7.1.1); baselines re-tested and folded. Nothing to report
upstream. Methodology lesson: "both platforms agree" only rules out the
EXECUTION environment — the judging toolchain was the same stale binary
on both sides. Cross-check the verdict tool too.

Original (now-retracted) analysis kept below for the record.
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
