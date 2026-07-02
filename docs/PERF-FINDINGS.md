# UML xfstests performance: where the time goes, and how to speed it up

Date: 2026-07-02. Kernel: btrfs-devel `for-next` 7.1.0-rc7 (UML). btrfs-progs v7.0.
Host: 32 cores. All numbers measured in this environment.

## Headline

Per-test wall time in UML is **fork/exec-bound**, not btrfs- or I/O-bound. The
btrfs operations themselves are fast; the cost is UML creating processes.

## Evidence

**btrfs operations are cheap** (in-guest, 3 GiB device):

| op | time |
|---|---|
| mkfs.btrfs -f | ~0.8 s |
| mount | ~0.11 s |
| umount | ~0.12 s |
| btrfs check | ~0.11 s |

A full mkfs+mount+umount+check cycle is ~1.2 s — yet a "fast" quick test takes
12–19 s. The gap is process creation:

**fork+exec cost** (1000× `/bin/true`):

| mode | per exec | 1000 execs |
|---|---|---|
| ptrace (default) | 29 ms | 29.2 s |
| **seccomp=on** | **16 ms** | **16.5 s** |

An xfstests test forks hundreds–thousands of short-lived processes (every `[ ]`,
`grep`, `sed`, `awk`, `_require_*`, mkfs, mount…). At ~29 ms/fork that is the
entire 12–19 s floor; generic/001 (~2500 forks) is ~75 s. In-shell loops with no
fork run in microseconds, confirming fork/exec — not the shell or I/O — is the cost.

## Lever 1: `seccomp=on` (verified ~1.6–1.9×, one flag)

UML 7.1-rc supports a seccomp-based syscall interception mode
(`seccomp=on` on the kernel command line) that avoids ptrace round-trips.

A/B on the same 7 tests (btrfs/001,007,017,025 generic/002,005,011):

| | ptrace | seccomp=on |
|---|---|---|
| wall clock | 140 s | **87 s** |
| per-test | 13–19 s | 7–13 s |
| result | Passed all 7 | Passed all 7 |

Just add `seccomp=on` to the boot command. No downside observed (tests still pass).

## Lever 2: parallel sharding (the big one, not yet built)

Each UML is single-core; the host has 32. Run N UML shards, each with its own
rootfs copy + ubd image set (one UML per image — UML flocks backing files).
~16 shards is realistic. This is a near-linear throughput multiplier and composes
with seccomp.

## Lever 3: split off the soak tail

Most quick tests are 8–20 s; a tail of ~37 do fsstress/fsx/dbench/fio/populate and
take minutes. Keep them out of "smoke" and run them on their own cadence. See
`rootless-uml/quick-slow.txt` (heuristic list) — **note it's marker-based, not
measured**; a real timed baseline (feasible once sharding exists) is the reliable
classifier. Already seen mis-marked both ways: btrfs/007 quick-fsstress is only
14 s, while generic/001 (no marker) is 75 s.

## Projected time for the full fast set (889 quick "fast" tests)

| config | est. wall time |
|---|---|
| serial, ptrace | ~3.5 h |
| serial, seccomp=on | ~2 h |
| **seccomp + 16 shards** | **~8–10 min** |

## What did NOT help / won't help much

- tmpfs-backing ubd images: btrfs ops are already fast; the bottleneck is CPU/fork,
  not disk. Marginal.
- Skipping post-test `btrfs check`: it's ~0.1 s — not worth losing the corruption
  check.
- A faster shell: xfstests requires bash; the cost is fork count, not shell speed.

## Bottom line

For a fast UML smoke: `seccomp=on` + exclude the ~37 soak tests + shard across
cores. seccomp is a free ~1.7×; sharding is the order-of-magnitude win.
