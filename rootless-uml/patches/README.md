# Kernel patches (auto-applied by build-uml-kernel.sh)

`build-uml-kernel.sh` applies every `*.patch` here (with `patch -p1`) once, right
after extracting a fresh kernel tree. Skip with `UML_PATCHES=none`.

## uml-adaptive-spin-handoff.patch

Experimental `arch/um` change. UML seccomp mode runs the guest as a two-thread
ping-pong (kernel thread ↔ stub) synced by a shared futex word; every guest
syscall is a `FUTEX_WAKE`+`FUTEX_WAIT` round-trip (~327 context switches per
fork+exec). This patch spins on the shared futex before `FUTEX_WAIT`, skipping the
blocking syscall + context switch when the peer flips it within the spin budget
(`STUB_HANDOFF_SPINS`, default 2000000). `FUTEX_WAIT` remains the fallback.

Measured on this WSL2 box: **327→71 context switches per fork+exec (~4.6× fewer),
~4.2–4.85× fork/exec throughput**, btrfs check still passes.

Validated on real xfstests (paired solo runs, same 7.2-rc1 source, patched and
unpatched simultaneously under identical host conditions; all 8 runs PASS):

| test        | patched | unpatched | speedup |
|-------------|---------|-----------|---------|
| btrfs/033   | 164s    | 508s      | 3.1x    |
| btrfs/036   | 201s    | 860s      | 4.3x    |
| generic/069 | 22s     | 396s      | 18x     |
| generic/449 | 322s    | 1497s     | 4.6x    |

i.e. the entire former "stall blacklist" (see docs/STALL-TRIAGE-FINDINGS.md)
drops back under a ~350s ceiling with the patch on.

Caveats (not yet upstream-ready): best case is an idle multi-core host (a spinning
thread burns a core); WSL2 exaggerates context-switch cost; needs bare-metal
validation and an adaptive spin-then-block backoff before it's mergeable. Set
`STUB_HANDOFF_SPINS=0` (or drop the patch) to disable. See
`docs/STABLE-CORE-FINDINGS.md` context and the wider profiling notes.
