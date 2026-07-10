# Stall-test triage: the "hang" blacklist is fork-bound slow tests, not hangs

## Headline

All 13 profiled "stall" tests from the supervised runner's blacklist were run to
completion in isolated UML probes (1800s in-guest timeout, 1500s host wall-cap):
**13 of 13 PASS** (generic/449 initially hit the batch wall-cap; a later solo run
passed in 1497s unpatched / 322s patched). None crashed. None produced a wrong
result. The 200s stall detector was mislabeling slow tests as hangs.

| test         | outcome              | guest dur* | bottleneck signal            |
|--------------|----------------------|-----------|-------------------------------|
| btrfs/033    | pass (solo probe)    | 467s      | fork storm (see below)        |
| generic/738  | pass                 | 195s      | —                             |
| generic/371  | pass                 | 205s      | xfs_io-heavy                  |
| btrfs/050    | pass                 | 228s      | —                             |
| generic/324  | pass                 | 264s      | xfs_io                        |
| generic/037  | pass                 | 267s      | —                             |
| generic/032  | pass                 | 269s      | xfs_io-heavy                  |
| generic/626  | pass                 | 306s      | —                             |
| generic/615  | pass                 | 492s      | xfs_io-heavy                  |
| generic/069  | pass                 | 497s      | —                             |
| generic/748  | pass                 | 657s      | xfs_io-heavy                  |
| btrfs/036    | pass                 | 1062s     | xfs_io-heavy                  |
| generic/449  | pass (solo re-run)   | 1497s     | fork-bound (322s with the spin patch) |

\* batch durations ran at 6-way concurrency and are inflated by contention
(btrfs/036 was ~211s solo in an earlier run vs 1062s here). Classification is
robust; absolute times are not benchmarks.

(btrfs/301 was excluded — it is the known qgroup UML artifact, already
QEMU-cross-checked; see QEMU-CROSSCHECK-FINDINGS.md.)

## Root cause (btrfs/033 deep-dive): the UML fork/exec floor

btrfs/033 does `for i in 10240..1: xfs_io -c "pwrite $((i*4096)) 4096"` —
10,240 sequential single-write process spawns. Three independent measurements
converge on fork/exec emulation as the entire cost:

- **Host scheduling profile (wprof)**: ~0s I/O-wait (not ubd/disk),
  ~23,400 context switches/s (the `linux`↔`uml-userspace` futex ping-pong),
  ~60 process forks/s, 100% on-CPU.
- **Guest sampling (mconsole sysrq t, 30-sample burst)**: `xfs_io` is the
  running task in 24–27/30 samples, but the btrfs write path appears in only
  1/30 — btrfs itself is idle; the time goes to process startup/teardown.
- **Arithmetic**: 10,240 forks at ~60/s ≈ 170s for the write loop alone.

This is precisely the cost the experimental adaptive-spin handoff patch
targets (patches/uml-adaptive-spin-handoff.patch). NOTE: the mainline-7.2-rc1
UML used for all these measurements was built WITHOUT that patch (it predates
the patch workflow); it applies cleanly to 7.2-rc1.

## Validated fix for fork-storm tests: batch the xfs_io invocations

Rewrite `for i in ...; do xfs_io -c "pwrite ..." file; done` as a single
xfs_io fed via stdin:

```sh
for i in `seq 10240 -1 1`; do echo "pwrite $(($i * 4096)) 4096"; done \
    | $XFS_IO_PROG -f -d $SCRATCH_MNT/foo >/dev/null
```

Validated in-guest at N=2048 (validate033-init.sh): **identical file size and
identical fiemap extent count (2050)** — the fragmentation that btrfs/033
exists to exercise is fully preserved — while the write phase drops from
104s to 4s (~26x; fork cost is linear so the full N=10240 gains more).
The fragmentation comes from backwards offsets + O_DIRECT, not from separate
processes. Candidate for upstreaming to fstests: speeds up every environment.

## Profiling toolbox on this host (WSL2) — what works

- **wprof needs kernel BTF** (WSL kernel rebuilt with CONFIG_DEBUG_INFO_BTF=y).
  Even with BTF, **code-level attribution does not work on WSL2**: no hardware
  PMU → on-CPU timer samples all land on idle/swapper; user-space stacks (which
  is where the UML guest kernel lives) never symbolize (`[U] <unknown>`).
  What IS reliable: scheduling data (`switch` events) — per-task on/off-CPU
  time, blocked-vs-preempted, offcpu durations, context-switch and fork rates.
  Flags: `--stacks=all` (attached form; `-S all` is a usage error), `-d <ms>`,
  capture needs sudo, replay (`-R -J out.json`) does not.
- **UML mconsole is the code-level substitute**: launch UML with `umid=NAME`,
  then drive `~/.uml/NAME/mconsole` (AF_UNIX DGRAM, request = u32 magic
  0xcafebabe, u32 version=2, u32 len, payload; reply = u32 err, u32 more,
  u32 len, payload). `sysrq t` returns fully-symbolized guest kernel stacks
  for all tasks; burst-sampling it ~30x gives a poor-man's guest profiler.
  `stack <pid>` and `proc <file>` also work. No root, no BTF, no PMU needed.

## Operational consequences

1. **Raise the supervisor STALL to ~300s** (or move the known-slow set to a
   dedicated low-concurrency tier). The completed-test histogram shows max
   completed = 195s sitting right at the old 200s line; the tail is thin.
2. The 891-test stable core can absorb most of the former blacklist once the
   threshold reflects reality; only genuinely-unbounded tests should stay out.
3. Re-measure after applying the adaptive-spin patch to the mainline build —
   if the ~4.2–4.85x fork/exec gain holds on real tests, most of the slow tier
   collapses into the normal tier.

## Tools added

- `rootless-uml/prof-init.sh` — guest init: run ONE test to completion with a
  1800s per-test timeout, record its duration.
- `rootless-uml/profile-stalls.py` — host orchestrator: N concurrent probes,
  mconsole sysrq sampling, pass/fail/hang + bottleneck classification, JSON out.
- `rootless-uml/validate033-init.sh` — the btrfs/033 rewrite equivalence check
  (extent-count comparison of fork-loop vs batched writes).
