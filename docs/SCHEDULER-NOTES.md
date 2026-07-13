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
