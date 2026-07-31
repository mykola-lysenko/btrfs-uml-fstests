# kmemleak baseline: btrfs corpus is leak-clean at for-next 374fd5d128d8

**Run:** 2026-07-31, full btrfs corpus (auto-all, 1130 tests) on
`linux-for-next-0731-kmemleak` — the pinned KERNEL_BTRFS SHA
(374fd5d128d8, 7.2.0-rc5 base) rebuilt with `KMEMLEAK=1`.
**Result:** 876 pass / 246 notrun / 0 confirmed failures (5 raw, all
passed solo — the known load-flake family) and **zero per-test kmemleak
reports across the entire corpus**.

This is the reference point: any `LEAKS(kmemleak reports):` line in a
future sweep is NEW signal against a known-clean baseline at this SHA.

## How the lane works
- `build-uml-kernel.sh KMEMLEAK=1` — leak-hunting kernel variant
  (CONFIG_DEBUG_KMEMLEAK, 64k object pool, auto-scan off). Never applied
  to the pinned gate/sweep kernels; build a separate artifact named
  `<pin>-kmemleak`.
- `shard-init.sh` mounts debugfs (also un-notruns btrfs/150-class tests)
  and exports `USE_KMEMLEAK=yes` iff the kernel exposes a writable
  `/sys/kernel/debug/kmemleak` — so the lane is opt-in BY KERNEL, no
  extra configuration.
- xfstests does the rest natively: `_detect_kmemleak` primes the tracker
  at ./check start, `_check_kmemleak` scans after EVERY test and writes
  `results/<test>.kmemleak` on findings — per-test attribution for free.
- `run-supervised.sh` aggregates any reports as a non-gating
  `LEAKS(kmemleak reports):` line.

## Cost
Corpus wall time 3347s vs 2392s plain (~1.4x) with SHARDS=9 MEM=1500M
BIG_SHARDS=2 MEM_BIG=3500M (kmemleak needs the extra guest memory;
keep the total inside the /dev/shm cap).

## Triage protocol for future leak reports
1. Rerun the leaking test solo xN on the kmemleak kernel (repeatability).
2. KVM crosscheck (build-x86.sh EXTRA_KCONFIG=DEBUG_KMEMLEAK...) — rule
   out UML-specific allocation patterns.
3. Verify the judging layer (kmemleak version/behavior) before drafting
   anything — the generic/753+754 lesson.
