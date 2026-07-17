# xfs baseline sweep #1 — triage (2026-07-16)

First full xfs run on the rig: 1592 tests (generic+xfs minus generic/027),
queue mode, 14+2 lanes, for-next-0710 + XFS_DEBUG. Wall 7855s.
**TOTAL: pass=959 notrun=328 failed=222 (~33 timeout)**
Raw logs: ~/uml-smoke/results/archive-* (next run archives them) +
xfs-sweep-1.log; solo-retry verdicts in shards/retry/results/.

## The one big cluster: 89 of 94 confirmed diffs
Every dm-backed test (dm-flakey crash-consistency family generic/034-343,
dm-error reflink family generic/250-283, error-handling 534-557, ...)
fails identically:
    ./common/rc:5407: /sys/fs/xfs/flakey-test.NNN/error/...: No such file
**Hypothesis (unverified):** udev-less rootfs. On normal systems
/dev/mapper/X is a udev symlink -> ../dm-N, so xfstests' _fs_sysfs_dname
resolves to dm-N, matching the kernel's /sys/fs/xfs/<disk_name>. Our
libdevmapper (DM_DISABLE_UDEV=1) mknods real nodes, name stays
"flakey-test.NNN", sysfs path doesn't exist -> stray stderr -> mismatch.
**Verify:** boot checkenv guest, dmsetup create + mount xfs, compare
`ls /sys/fs/xfs/` vs `_fs_sysfs_dname`. **Fix candidates:** (a) rig: make
/dev/mapper entries symlinks post-dmsetup (shard-init shim wrapping
dmsetup, or `dmsetup mknodes` behavior); (b) upstream xfstests:
_fs_sysfs_dname could resolve via `stat -c %t:%T` -> /sys/dev/block ->
dm name — works without udev, arguably a genuine portability patch.
NOTE: this suppressed the *real* signal of ~89 tests — after the fix they
must all re-run before we claim xfs crash-consistency coverage.

## Independent confirmed failures (5 + 1)
- **xfs/083** — "xfs_repair did not fix everything" after corruption.
  REAL-BUG CANDIDATE (repair gap). QEMU crosscheck first.
- **generic/473** — fiemap reports [128..135] where golden expects
  [128..255]: extent granularity difference. Kernel-behavior candidate;
  QEMU crosscheck (remember the third-strike lesson before calling it
  an artifact).
- **generic/270** — SOLVED rig config: CONFIG_TMPFS_XATTR unset, so
  setcap on /tmp-copied fsstress fails. Enable (+TMPFS_POSIX_ACL) in
  next kernel rebuild.
- **generic/454** — unexpected "No complaints about ..." informational
  lines in output: xattr/unicode tooling difference, likely missing
  misc-filter dependency in rootfs. Rig-level, investigate.
- **xfs/013** — ENOSPC filling scratch even at 8G solo. Sizing/geometry
  question, not obviously a bug.
- **xfs/006** — [failed] (exit status, no .out.bad): error-handling test
  (uses the same sysfs error knobs!) — probably dm-sysfs cluster via a
  different failure shape. Recheck after cluster fix.

## Flaky under load (passed solo)
generic/415, generic/691 — btrfs runs saw the same class; park.

## Timeouts (~33) + xfs/136
Not yet triaged individually; overlaps the fuzzer drain. Of note:
**xfs/136 ran >73 min SOLO with FSTESTS_PER_TEST_TIMEOUT=1300 never
firing** — the per-test timeout mechanism has a hole (does it wrap only
the test script, not post-test fsck/repair? xfs_repair on the huge
fragmented image may be the sink). Investigate the timeout wrapper.

## Policy decisions this run
- xfs dangerous_* groups (193 tests) added to blacklist-xfs.txt:
  baseline sweeps exclude fuzzers; fuzz campaigns get dedicated runs.
- 12 tests missed solo-classification (retry lane cut at fuzzer block):
  xfs/237,240,264,401,402,403,438,504,542,556,605,656 — re-run solo in
  the xclass guest (results pending as of this commit).

## Rig bugs found & fixed during this sweep
1. queue-init claim markers stranded in claimed/ forever (CLAIMED
   accumulated in a $() subshell) — fixed, markers via stdout.
2. run-queued requeue_lane glob `claimed/*.$n` aliased lane 5 with 15,
   0 with 10 — requeued other lanes' finished work. Fixed: exact-suffix.
3. queue-init pre-T3 timeout 900 -> 1300.
4. (lesson) pkill -f patterns match your own watcher/task cmdline —
   use [b]racket patterns.

## Next steps
1. Verify + fix dm-sysfs naming; re-run the 89-test cluster.
2. QEMU crosscheck xfs/083 and generic/473.
3. Kernel config additions next rebuild: TMPFS_XATTR, TMPFS_POSIX_ACL.
4. Investigate per-test timeout hole (xfs/136).
5. Triage the ~33 timeouts once cluster noise is gone.
