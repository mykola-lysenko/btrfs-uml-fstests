# Btrfs bug-finding: assessment of the two repos

Date: 2026-07-01

Two repos in this folder aimed at finding btrfs bugs:
- `btrfs-uml-fstests/` — run fstests against real btrfs inside User Mode Linux.
- `btrfs-tla-verification/` — TLA+ models + bpftrace tracing kit for "formal verification".

## Verdict

The two repos target two different bug classes; only one is actually a
bug-*finding* tool, and UML is a poor fit for the bug class the other repo cares
about.

### `btrfs-uml-fstests` — a real, runnable harness (the valuable half)
- `setup-uml-env.sh` builds a UML kernel with btrfs debug options, bootstraps a
  Debian rootfs, builds xfstests, generates a UML-compatible test list, validates
  a boot. Executes real kernel code against real btrfs → can genuinely surface
  bugs/regressions.

### `btrfs-tla-verification` — mostly documentation dressed up as verification
- The 66 TLA+ models encode *already-known* CVEs (2023–2025) **by construction**.
  Example: `BtrfsCOWPath.tla` literally does
  `crash_uaf' = IF node_state = "Freed" THEN TRUE`. TLC "finding" the UAF only
  confirms the model was written to contain one — circular.
- Models are 5–6-variable cartoons, not faithful to btrfs algorithms. Reports
  (authored by "Manus AI") overclaim ("mathematically proving absence of
  concurrency violations" for a 20-state model).
- **As written, this repo cannot find a new btrfs bug.** Treat it as
  spec/documentation, not a discovery engine.
- The one grounded piece: the **bpftrace tracing kit** hooks real btrfs functions
  (`btrfs_tree_lock`, `btrfs_cow_block`) and real tracepoints (96 refs). Could be
  repurposed as a runtime oracle. But the Python checkers re-implement the toy
  invariants and the simulators feed synthetic buggy-by-construction traces, so
  the pipeline currently proves nothing about a live kernel.

## Core mismatch
- The TLA+ models are about **SMP concurrency races** (ABBA deadlock, UAF-under-COW,
  rescan-vs-disable, double-add).
- **UML can't trigger those**: it runs the kernel as an essentially single-threaded
  userspace process with no real SMP. KASAN is limited on UML; KCSAN essentially
  doesn't work there.
- The fstests setup also *excludes* `dm-flakey`/`dm-log-writes` (crash-consistency,
  power-fail) — exactly where btrfs bugs concentrate — and `/dev/shm`-backed images
  make those meaningless anyway.
- Net: the fast UML harness is optimized for the bug classes least likely to be
  interesting and can't exercise the concurrency bugs the other repo targets.

## Is it a bad idea?
Not fundamentally, but:
1. **Formal-methods-finds-kernel-bugs is a mirage here.** A TLA+ model that finds a
   *new* btrfs bug needs fidelity to real algorithms = multi-month research, and
   TLC state-space explosion caps scaling.
2. **New btrfs bugs are hard and heavily tooled already.** State of the art:
   syzkaller (syscall fuzzing) + KASAN/KCSAN/lockdep + fstests-with-dm-flakey on
   mainline/-next. A released stable kernel (6.19.9) has already passed the fstests
   you'd run.

## How to proceed (the real plan — revisit later)
Bet on the fstests harness, reconfigured for bug-finding not CI throughput:
- Move off UML to **qemu/KVM with multiple vCPUs** for real SMP + working
  KCSAN/lockdep. Keep UML only for fast smoke runs.
- Enable debug detectors: `KASAN`, `KCSAN`, `PROVE_LOCKING`/lockdep,
  `DEBUG_MUTEXES`, `DEBUG_LIST`, `PROVE_RCU`. (BTRFS_DEBUG/ASSERT/REF_VERIFY
  already on — good.)
- Test **mainline / -rc / linux-next**, not released stable. Fix script's
  `BASE=/home/ubuntu` hardcode and `linux-6.19.9` dir name mismatch vs its own
  "latest stable" download logic.
- **Run the excluded tests**: dm-flakey/dm-log-writes crash-consistency on
  persistent storage under qemu — highest-yield category the setup throws away.
- Add long-run `fsstress`/`fsx` soak; seriously consider **syzkaller** on btrfs
  (highest-ROI btrfs bug finder).

Salvage tracing kit as a runtime oracle (run bpftrace during fstests/fsstress,
check invariants live) — but rewrite invariants to be meaningful and baseline
false-positives against a known-good kernel first. Keep TLA+ models as design
notes for which invariants to watch.

## Current focus (this session)
User wants to characterize the **UML smoke-test** path specifically: how fast, what
coverage, current gaps, and how to (a) speed up and (b) cover more features in UML.
Smoke tests are still a useful mechanism. See SMOKE-TEST-FINDINGS.md (WIP).
