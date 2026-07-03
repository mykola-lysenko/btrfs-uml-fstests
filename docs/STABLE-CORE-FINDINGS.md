# Stable core of the btrfs quick group under rootless UML

Goal: find the subset of the xfstests **btrfs quick** group (926 tests) that runs
**predictably** under the rootless-UML pipeline — passes/not-runs the same way
every time, without hangs or crashes — so it can serve as a fast regression core.
Kernel under test: btrfs-devel `for-next` 7.1.0-rc7 built for `ARCH=um`.

## Result

Full quick group, memory-safe config (8 shards × 1400M), empty blacklist:

| bucket | count | meaning |
|--------|------:|---------|
| **Stable core** | **891** | 504 pass + 387 clean not-run — reproducible every run |
| Slow tier | 23 | pass, but exceed the 120 s per-test timeout (need a longer budget) |
| Residual failures | 12 | genuine output mismatches — mostly environment, a few to triage |
| Hangs / crashes | **0** | — |

Lists: `rootless-uml/{stable-core,slow-tier,residual-failures}.txt` (full list: `rootless-uml/quick-all.txt`).

## What it took to get there

1. **Environment gaps produced false failures.** The stripped-down rootless rootfs
   was missing pieces real xfstests assumes:
   - `getconf` (used by e.g. btrfs/053) — recent `libc-bin` debs omit the binary; we
     copy it from the host in `assemble-rootfs.sh`.
   - `/dev/fd` + `/dev/std{in,out,err}` — needed by tests using bash process
     substitution `<(...)` (e.g. btrfs/031); created in the init scripts.
   - `util-linux mount` still returns EPERM under UML even as root, so we keep the
     busybox `mount` wrapper — which costs a few *cosmetic* mismatches (e.g.
     generic/050 diffs only on a mount message), not real bugs.

2. **A per-test timeout** (`timeout -k 10 $FSTESTS_PER_TEST_TIMEOUT`, patched into
   `check`) bounds slow tests so one doesn't stall a whole shard.

3. **A self-healing supervisor** (`rootless-uml/run-supervised.sh`). Each shard is one
   UML running `./check` serially; a test wedged in uninterruptible (D) state can't be
   killed by the per-test timeout and stalls the shard. The supervisor watches each
   shard and, on a **stall** (stuck > `STALL`s, past the per-test timeout → a true
   hang) *or* a **crash** (UML died without a clean DONE marker), it kills the shard,
   blacklists the offending test, and **relaunches with the remaining tests** — results
   accumulate across restarts, so one bad test costs seconds, not the whole slice.

## The key lesson: it was memory overcommit, not kernel bugs

Early runs showed an ever-growing list of "hangs" and "Kernel panic — Kernel mode
signal 7" (SIGBUS) "crashes" — and the blacklist never converged, because each run
failed *different* tests. Root cause: **host memory overcommit.**

- This box is WSL2: **32 GB host, but the VM was capped at ~15.6 GB** (WSL2's default
  ~50%). It is **CPU-rich (32 cores) but RAM-bound** — so shard count is limited by
  RAM, not cores.
- **16 shards × 1500M = 24 GB requested on a 15.6 GB VM.** Under load, whichever shard
  lost the memory race got a SIGBUS on a failed mmap → UML kernel-mode panic. The
  "flakiness" was just *which* shard lost.
- Proof: all 18 tests that panicked under 16×1500M ran with **zero crashes** at
  4×2500M with headroom; and the full 926 at 8×1400M finished with **0 hangs, 0
  crashes, empty blacklist**.

**Sizing rule:** `shards × per-shard-MEM` must fit the VM RAM (leave ~3–4 GB for
host+cache). Safe here: `8 × 1400M` at 15.6 GB; `16 × 1400M` after raising the VM to
24 GB (`memory=24GB` in `%USERPROFILE%\.wslconfig`, then `wsl --shutdown`).

## Reproduce

```sh
# one-time build (host side): kernel, rootfs (getconf + /dev/fd), xfstests (+timeouts)
rootless-uml/build-uml-kernel.sh
rootless-uml/fetch-rootfs-pkgs.sh && rootless-uml/assemble-rootfs.sh
rootless-uml/build-xfstests-hostside.sh

# run the full quick group with the supervisor at a memory-safe config
SHARDS=8 MEM=1400M LIST=rootless-uml/quick-all.txt \
  KERNEL=~/uml-smoke/linux-btrfs-for-next/linux \
  rootless-uml/run-supervised.sh
```

## Remaining work

- **Slow tier (23):** re-confirm they pass with a longer per-test timeout, then fold
  into the core.
- **Residual failures (12):** triage `btrfs/{058,089,289,295,330}`,
  `generic/{042,050,131,306,571,786,787}` — separate the environment artifacts
  (busybox mount, termcap) from any genuine btrfs behaviour differences.
