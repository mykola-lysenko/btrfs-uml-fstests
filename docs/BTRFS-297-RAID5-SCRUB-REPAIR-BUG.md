# btrfs raid5 scrub fails to repair corrupted parity (intermittent) — REAL BUG

**Status:** QEMU/KVM-confirmed 2026-07-15. First real btrfs kernel bug of the
project. Mechanism instrumentation pending (next session).

## Signature
fstests btrfs/297, raid5/2-device section: test corrupts the P stripe with
0xff (direct write, fs unmounted), mounts, runs `btrfs scrub start -BdR`,
unmounts, reads parity back directly from the device. Intermittently the
parity is STILL 0xff — the repair write never landed — and
`btrfs check --check-data-csum` confirms the fs is left with bad parity.

## Rates observed
- QEMU/KVM x86-64, 7.2.0-rc1: 1/10 solo
- UML 7.2.0-rc1: 1/5 and 2/5 solo (two kernel builds differing only in
  STUB_HANDOFF_SPINS timing), plus one confirmed-solo in a full run
- UML 7.1.0-rc7: 1/5 — but that failure had parity CORRECTLY repaired (aa)
  and only the offline check failed; possibly a second mode, needs reruns

## Why we believe it
- Passes the full artifact filter that killed all 7 prior candidates:
  reproduces on real hardware, solo (no load), verified by direct device
  readback, on two independent platforms.
- The guarded area is exactly commit 486c737f7fdc ("btrfs: raid56: always
  verify the P/Q contents for scrub") — the test carries it as
  _fixed_by_kernel_commit; the guard is firing again.
- NOT related to our rbio_gen_syndrome patch: the failing section is raid5
  (2 devices), which never calls raid6_gen_syndrome; the raid6/3-dev section
  (our patched path) repairs correctly (aa) in the same failing runs.

## How it was flushed out
The T7 fork-storm investigation built a STUB_HANDOFF_SPINS=100k kernel; the
timing shift raised the failure rate enough for the solo-retry classifier to
CONFIRM it instead of binning it as load-flake. All previous full runs
happened to pass it (or attributed the _check_dmesg WARN on 7.2 to the
RAID6_MIN_DISKS issue).

## Repro assets
- rootless-uml/probe-297.sh — N fresh-boot solo iterations per kernel
- ~/uml-smoke/results/qemu-297-x10.out — the KVM confirmation (iter 10)
- ~/uml-smoke/results/297-*.{out.bad,parity} — failed-iteration artifacts

## Next (mechanism instrumentation, per standing rule before reporting)
1. dmesg + scrub -BdR statistics on a failing iteration (does scrub even
   DETECT the parity mismatch? csum_errors/super_errors counters).
2. Read scrub_rbio/finish_parity_scrub paths: how dbitmap/scrubp decide
   writeback; suspect: parity verify skipped when data csums all pass +
   some cached/raced state.
3. Bisect era: does 6.12 flake? (binary exists: linux-6.12).
4. Report to linux-btrfs with repro rates + both modes.
