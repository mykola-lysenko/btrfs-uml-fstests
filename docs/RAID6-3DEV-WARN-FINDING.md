# btrfs 3-device RAID6 trips a new raid6-library WARN on 7.2.0-rc1

**Status:** both-platform confirmed (UML + x86/KVM), fix written and validated in
QEMU, patch drafted (`upstream-kernel/0001-btrfs-handle-3-device-RAID6-*.patch`).
**Found:** 2026-07-15, by the T3 memory-calibration run (serendipitously — first
run of the full bigmem set on the 7.2.0-rc1 kernel).

## Symptom

fstests **btrfs/297** fails `_check_dmesg` on 7.2.0-rc1 with:

```
WARNING: lib/raid/raid6/algos.c:48 at raid6_gen_syndrome+0x4d/0x60
Workqueue: btrfs-rmw rmw_rbio_work
Call Trace:  rmw_rbio → raid6_gen_syndrome
```

Only the **first** raid6 3-device test per boot fails — the assert is
`WARN_ON_ONCE`, so one test per boot eats the warning and every later one
passes. In a full-suite run this looks like a flaky single failure.

## Mechanism (all three links verified in source)

1. `lib/raid/raid6/algos.c:48` — `WARN_ON_ONCE(disks < RAID6_MIN_DISKS)`,
   with `RAID6_MIN_DISKS = 4` (`include/linux/raid/pq.h:12`).
2. `fs/btrfs/volumes.c` — `btrfs_raid_array[BTRFS_RAID_RAID6].devs_min = 3`:
   btrfs deliberately supports 3-device RAID6 (1 data + P + Q).
3. `fs/btrfs/raid56.c:1413` and `:2647` — btrfs calls
   `raid6_gen_syndrome(rbio->real_stripes, ...)` with `real_stripes = 3`.

btrfs/297's workload creates a 3-device raid6 scratch fs; the first RMW write
fires the WARN.

## Provenance — the WARN is deliberate

Culprit: **`2790045a62eb` "raid6: warn when using less than four devices"**
(Christoph Hellwig, 2026-05-18, part of the `lib/raid6` → `lib/raid/raid6`
refactor, merged for 7.2). The commit message quotes H. Peter Anvin ("The
RAID-6 code has *never* supported only 3 units") and **explicitly anticipates
btrfs tripping it**:

> While md never allowed less than 4 devices, btrfs does. This new warning
> will trigger for such file systems ... If btrfs wants to fix this, it should
> switch to transparently use three-way mirroring underneath, which will work
> as P and Q are copies of the single data device by the definition of the
> Linux RAID 6 P/Q algorithm.

So this is NOT a library bug to "fix" by lowering the minimum — the sanctioned
direction is a **btrfs-side** special case. No btrfs-side fix was queued in
btrfs for-next (Jul 10 snapshot) or visible on patchwork as of 2026-07-15.

## Why 3-dev degenerates to mirroring (verified against int.uc)

`gen_syndrome(disks=3)`: `z0 = disks-3 = 0`, the inner Galois loop never
executes, so `P = D0` and `Q = g^0·D0 = D0`. Both parities are byte copies of
the single data stripe. (Also verified empirically: scrub of the affected fs
reports status 0 on all devices right after the WARN.)

## The fix

`fs/btrfs/raid56.c`: new helper `rbio_gen_syndrome()` used by both call sites
(RMW `generate_pq_vertical_step` and scrub `verify_one_parity_step`):

```c
if (rbio->real_stripes < RAID6_MIN_DISKS) {
        memcpy(pointers[rbio->nr_data],     pointers[0], step);  /* P */
        memcpy(pointers[rbio->nr_data + 1], pointers[0], step);  /* Q */
        return;
}
raid6_gen_syndrome(rbio->real_stripes, step, pointers);
```

Matches the existing inline RAID5 fallback idiom in the same functions. The
recovery helpers (`raid6_recov_2data/datap`) did not grow a min-disks assert,
so the read-repair path is untouched. Geometries ≥ 4 devices are bit-for-bit
unaffected.

## Validation

| platform | kernel | result |
|---|---|---|
| UML | 7.2.0-rc1 unpatched | btrfs/297 fails `_check_dmesg` (WARN in dmesg) |
| QEMU/KVM x86-64 | 7.2.0-rc1 unpatched | iter 1 fails with identical stack; iters 2–3 "pass" (WARN_ON_ONCE) — `results/qemu-297-raid6warn.out` |
| QEMU/KVM x86-64 | 7.2.0-rc1 + fix | btrfs/297 ×3 all pass, zero warnings — `results/qemu-297-fixed.out` |
| UML | 7.2.0-rc1 + fix | btrfs/297 passes (7s); full fstests raid group (66 tests): 52 pass / 14 notrun / 0 fail, zero dmesg artifacts (per-test verified, not just aggregate) |

## Notes for the report / submission

- `Fixes: 2790045a62eb ("raid6: warn when using less than four devices")`
- Cc: linux-btrfs, Christoph Hellwig, David Sterba; the WARN commit went
  through Andrew Morton's tree.
- The rig-level lesson: the aggregator's fail regex (`output mismatch|\[failed`)
  does not catch `_check_dmesg` failures — this finding was invisible in the
  summary line and was caught only by per-test accounting. Fix the aggregator.
