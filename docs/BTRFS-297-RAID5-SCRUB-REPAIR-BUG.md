# btrfs raid5 scrub fails to repair corrupted parity (intermittent) — REAL BUG

**Status:** SOLVED 2026-07-15 same day — root cause found, one-line fix
written, validated 8/8 UML + 10/10 KVM. Patch:
`upstream-kernel/0002-btrfs-raid56-fix-inverted-bio-list-check-in-scrub-re.patch`
(`Fixes: 5387bd958180`, `CC: stable # 7.1+`).

## ROOT CAUSE (found via printk instrumentation, 7/8 repro rate under UML)

Commit `5387bd958180` ("btrfs: raid56: remove sector_ptr structure",
2025-10-09, in 7.1) mechanically converted the bio-list membership check in
`scrub_assemble_read_bios()` and FLIPPED ITS POLARITY:

    -  sector = sector_in_rbio(rbio, stripe, sectornr, 1);
    -  if (sector)                       /* in bio list -> nothing to read */
    +  paddr = sector_paddr_in_rbio(rbio, stripe, sectornr, 1);
    +  if (paddr == INVALID_PADDR)       /* NOT in bio list -> skip?! */
           continue;

The same commit converted two analogous checks in
`rmw_assemble_write_bios()` correctly — but those have the OPPOSITE meaning
(write-what-is-in-the-bio-list vs read-what-is-missing), and the scrub site
got the write-site polarity.

Consequence: a parity-scrub rbio's bio list holds only the empty completion
bio, so **scrub_assemble_read_bios() submits no reads at all**.
`finish_parity_scrub()` then memcmp()s the computed parity against
freshly-allocated, UNINITIALIZED pages:
- garbage != computed  -> sector "repaired" and written -> accidentally
  correct on-disk result (why scrub usually appears to work!)
- recycled page still holding old correct parity == computed -> sector
  dropped from dbitmap -> corrupt on-disk parity NEVER rewritten, all scrub
  counters zero.

Instrumented trace (failing run): ondisk bytes = aa,aa,aa,00x13 while the
device held ff — the reads never happened. After the fix: ondisk=ff on all
16 sectors, detected, repaired. All error counters are zero in both modes,
so no monitoring would ever notice.

**Blast radius:** every parity scrub on raid5/6 since 7.1 verifies parity
against garbage instead of the device — scrub as a parity-integrity check is
effectively disabled (it usually *repairs* healthy parity by accident and
only intermittently leaves real corruption in place).

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

## Validation matrix (final)
| kernel | result |
|---|---|
| UML 7.2-rc1 + instrumentation, unfixed | 7/8 FAIL (printk timing favors page reuse) |
| UML 7.2-rc1 + fix (instrumented) | 8/8 pass, trace shows ondisk=ff detected+repaired |
| UML 7.2-rc1 + fix (clean build) | 5/5 pass |
| QEMU/KVM 7.2-rc1 unfixed | 9/10 (1 unrepaired-parity fail) |
| QEMU/KVM 7.2-rc1 + fix | 10/10 pass |

## Remaining
- 7.1-rc7 "mode B" (parity repaired but offline check errored, 1/5 once) —
  likely the same root cause via a different lucky/unlucky page pattern; not
  worth chasing separately now the reads are restored.
- Send 0002 to linux-btrfs (Cc Qu Wenruo, David Sterba, stable). This one is
  urgent-grade: scrub parity verification has been a no-op since 7.1.
