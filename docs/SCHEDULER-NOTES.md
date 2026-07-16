# Scheduler evaluation: LPT vs work-queue (T2)

## Verdict: LPT retained. The work queue does NOT beat it.

| runner            | auto-group wall | notes |
|-------------------|-----------------|-------|
| LPT (best)        | 2343s           | ±1s projected lane balance |
| LPT (typical)     | 2733s           | host-variance band |
| Work-queue (T2)   | 2779s           | same-to-slower |

## Why the queue lost (the useful lesson)

1. LPT with a mature times-db (results/times-db.txt, ~880 tests) projects
   lane load to ~1s. Its theoretical weaknesses -- projection error and
   the straggler tail -- are the queue's only advantages, and they're worth
   ~nothing once times are known. The queue wins only for unknown/highly
   variable per-test times.
2. The queue pays a real tax: LPT runs `./check t1..tN` ONCE per lane; the
   queue runs `./check` per small batch (3) to keep balancing granular, so
   it re-pays check's startup (~source common/*, config) ~30x per lane.
   That ~= the 400s it trailed by. Bigger batches recover it but kill the
   balancing that is the queue's only point -- unwinnable tension.

## Disposition
- run-supervised.sh (LPT) is the default runner.
- run-queued.sh + queue-init.sh kept in-tree as a documented option; its
  unique, non-speed features (OOM-requeue self-healing; btrfs-first
  ordering for dev-loop time-to-signal) may be worth grafting onto the LPT
  runner later, but neither is a wall-time win. It has one known cosmetic
  bug: comp_tests() doesn't count failed tests as completed, so requeue
  returns already-run failures to the queue (no work lost -- the
  solo-retry lane still classifies them; the "fully drained" invariant is
  just violated on runs with failures).

## Where speed actually remains
Scheduling is solved (at the floor). The remaining lever is T3: more lanes
via smaller guest memory. RSS "measurement" (T1) showed guests fill
whatever RAM they're given with page cache (values cluster at mem=), so
per-test need isn't extractable that way; the real test is empirical --
trial slim mem=1000M on the quick group, and if no OOM adopt ~14 slim + 3
fat within the 22G /dev/shm cap (see wsl2-memory-cap). Projected auto ~24
min. T3 runs on the LPT runner.

## T3 addendum (2026-07-15): memory retier — ceiling broken, constraint moved

Calibration (31 hungriest tests forced onto mem=1000M lanes): all pass; the
old 38-entry bigmem list was almost entirely shm-exhaustion bystanders.
rss-per-test.txt maxes are ceiling-contaminated (page cache fills whatever
mem= allows) — only LOW values in that DB carry information.

New tiering: 14 slim x 1000M + 2 fat x 3000M = 20G declared inside the 22G
/dev/shm. bigmem pruned 38 -> 10: five long tests never tried at 1000M
(btrfs/010/062/080/276, generic/449), two that need the 8G *disks* not the
RAM (generic/746/747, they notrun on 3G images — silent coverage loss if
demoted), the two blacklisted UML-too-slow entries, and generic/551 (the one
genuine guest-OOM at 1000M ever observed: aio-dio-write-v, caught by the
oom-killer in-guest during the validation run).

Validation on the 1130 auto group: wall 2607s, 870 pass, 0 hangs, 0 crashes,
0 SIGBUS, 8 raw failures ALL passed solo (0 confirmed). The 2607s is only 5%
under the 11-lane 2733s because three one-time effects ate the gain, each now
fixed:
  1. generic/415's 862s was in an isolated calibration DB, not the real
     times-db -> LPT saw median, scheduled it LAST -> ~500s straggler tail.
     Self-healed: this run harvested 415/416 times into the real DB.
  2. generic/415+416 crossed the 900s in-guest timeout under 16-lane load
     (exit 124). Timeout now 1300s, STALL raised to 1450 (invariant:
     STALL > in-guest timeout).
  3. generic/551 OOM-failed on slim -> now bigmem.
Next full run should land ~1640s LPT floor + tail (~29-30 min projected).

Structural result: the memory ceiling is GONE (20G declared, zero SIGBUS,
free never below ~10G). The binding constraint at 16 lanes is CPU/IO
contention: per-test times run ~15-25% over their 11-lane values. Further
lanes (memory now allows ~20) face diminishing returns; measure before
adopting. Death-classifier note: all 35 historical "crashes" reclassified as
host shm-sigbus — the classifier now defers memory victims to the fat retry
lane instead of blacklisting (coverage can no longer be silently lost to a
tier miscalibration; the T3 validation exercised exactly this path for 551).
