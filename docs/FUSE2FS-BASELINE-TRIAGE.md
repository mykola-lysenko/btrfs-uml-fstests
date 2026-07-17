# fuse2fs baseline sweep — triage (2026-07-17)

First complete fuse corpus run (sweep-6 after five aborted attempts —
see rig-bug ledger below). 792 generic tests, FSTYP=fuse +
FUSE_SUBTYP=.fuse2fs (fuse2fs 1.47/libfuse2 over ext4-formatted ubd),
14+2 lanes, wall 918s.

**TOTAL: pass=217 notrun=509 failed=66 → confirmed-solo 65, flaky 1
(generic/676). allow_other+default_permissions retry: 13 recovered
(rig config), 1 notrun → 51 real survivors.**

## Survivor clusters (51)
1. **fsx zero-range data divergence — generic/363, 521, 522.**
   REAL-BUG CANDIDATES: fsx op-log dumps around zero_range through
   fuse2fs = data-integrity class. Next: extract fsx ops, minimal
   reproducer, compare against loop-mounted ext4; if confirmed this is
   an e2fsprogs (fuse2fs) report.
2. **"Mounting read-only." — generic/294, 306, 452.** fuse2fs cannot
   replay a dirty ext4 journal ("Writing to the journal is not
   supported") and falls back to ro. Genuine fuse2fs limitation;
   crash-consistency tests can't pass by design. Report-or-notrun
   discussion for upstream.
3. **open_by_handle ESTALE — generic/426, 467, 477, 756, 777.** fuse
   file-handle semantics; likely needs an fstests _require guard
   (upstream patch candidate) unless fuse2fs can support persistent
   handles.
4. **mount-helper bypass — generic/409, 410, 411, 589.**
   '/bin/sh: /dev/ubdc: Permission denied' = mount.fuse3 executing the
   device again: these tests mount with paths/opts that skip our
   mount.fuse.fuse2fs helper (bind/propagation/by-label variants).
   RIG issue; fix helper dispatch, then re-run.
5. **fallocate EPERM — generic/683, 684** (+ possibly in cluster 1's
   root cause): zero-range/punch modes not wired through fuse2fs.
6. **Unclassified 7 — generic/035, 321, 335, 341, 348, 533, 790**
   (mostly dm-flakey/log-writes family): diff head empty, read
   individually. Likely overlaps cluster 2's journal story.
7. Singles: generic/091 (mmap writes disabled through fuse), 319 (ACL
   mask propagation), 535 (statx after rename), 633 (setid binaries),
   637 (xattr?), plus remainder of the 51 not listed above.

## Rig lessons ledger (cost: five aborted sweeps in one afternoon)
1. queue-init lacked the fuse branch (only shard-init had it) → sweep-1
   792 tests inhaled in 30s by instant-abort ./check.
2. `| head -5` on the launch pipeline SIGPIPE-killed the supervisor.
3. Shared hostfs /mnt + libfuse2 non-empty refusal → synchronized
   all-lane collapse at ~t+300s (sweep-2). Fix: per-guest tmpfs /mnt.
4. Self-poisoning via post-unmount debris → -o nonempty (parity with
   kernel mounts; libfuse3 deleted the check).
5. Zombie guests from a not-yet-dead prior run contaminated sweep-5 →
   run-queued startup interlock (with $-anchored self-count).
6. Sick-lane guard: silent/verdict-less ./check batches requeue; two
   strikes exits the lane loudly. batches.log per-batch forensics.

## Next steps
1. Fix helper-bypass (cluster 4), re-run those 4.
2. fsx forensics on 363/521/522 → minimal repro → compare vs native
   ext4 loop mount; report to e2fsprogs if it holds.
3. Read the 7 unclassified diffs; fold into clusters.
4. Draft the fstests _require guards (clusters 3/5) as upstream
   patches — pairs well with the dm-sysfs _fs_sysfs_dname portability
   patch from the xfs triage.
5. Journal-ro limitation: raise on linux-ext4/fuse lists whether
   fuse2fs should refuse-rw or the tests should _notrun.
