# btrfs (NO_HOLES): committed i_size outruns data — null files after crash

**Status:** root-caused and A/B-proven 2026-07-15 late session. THIRD real
finding. Deterministic real-hardware reproducer — no UML needed.
**2026-07-16:** T9 done — framing decided (report-first, recommend kernel-side
clamp, no patch attached). Lore prior-art check: no existing 044-046/no-holes
thread found (lore Anubis-blocks us; searched via mirrors). Source comment on
btrfs_inode_safe_disk_i_size_write() confirms the skip was justified on
metadata validity only. Report draft:
`upstream-kernel/REPORT-NO-HOLES-NULL-FILES-DRAFT.md` (3 open items inside).
**Same-kernel A/B rerun (for-next-0710, 2026-07-16):** defaults+commit=1
8/8 FAIL vs ^no-holes+commit=1 0/8, back-to-back under identical 10-guest
load. All open items closed — report is SEND-READY pending user go.

## Symptom
generic/044 (and family 045/046): after `_scratch_shutdown` + remount, files
show "non-zero size but no extents". Was misclassified for a week as a
"UML-load artifact" on the strength of 0/22 on KVM — the same evidence
pattern that hid the raid5 scrub bug. The KVM runs simply never opened the
timing window.

## Mechanism (verified in source + on-disk forensics)
1. Test does `pwrite 64k` (buffered, no fsync) then `truncate 64k`
   (same-size). `btrfs_setsize()` routes newsize==oldsize into the SHRINK
   path (fs/btrfs/inode.c:5251 else-branch) -> `btrfs_truncate()` ->
   `btrfs_inode_safe_disk_i_size_write()`.
2. `btrfs_inode_safe_disk_i_size_write()` clamps disk_i_size to the
   contiguous-from-0 range of COMMITTED extents — but ONLY via
   `inode->file_extent_tree`, and `btrfs_init_file_extent_tree()` SKIPS
   allocation when the fs has NO_HOLES (fs/btrfs/inode.c:3813) — the mkfs
   DEFAULT since btrfs-progs 5.15. With the tree NULL, disk_i_size = i_size,
   unconditionally.
3. A transaction commit that lands between the truncate and delalloc
   writeback persists `size=65536 nbytes=0` with zero EXTENT_DATA items
   (on-disk dump: results/t6/corrupt-1.img, inode 1174, transid 9).
   Shutdown before the next commit -> file of nulls. fsck-clean (NO_HOLES
   makes it a legal hole), so nothing ever flags it except generic/044.
4. Fast hardware hides it: the whole test fits inside one 30s commit
   interval, so either nothing commits (files absent — pass) or everything
   commits (extents present — pass). Slow/loaded systems (UML) straddle the
   commit timer, or ANY system with `-o commit=1`.

## A/B proof matrix
| platform | mkfs | mount | result |
|---|---|---|---|
| KVM x86-64, no load | default (no-holes) | -o commit=1 | **15/15 FAIL** |
| UML, 10-guest load | default (no-holes) | -o commit=1 | **8/8 FAIL** |
| UML, 10-guest load | **-O ^no-holes** | -o commit=1 | **0/8 fail** |
| UML, 10-guest load | default | default | 1/10 fail (baseline flake) |

Single-variable toggle of NO_HOLES flips the result completely.

## Framing for upstream (to decide tomorrow)
- The file_extent_tree NO_HOLES skip dates to its introduction (Josef's
  per-inode file extent tree, ~2020, 41a2ee75aab0-era): rationale was
  metadata VALIDITY (a hole is representable so fsck stays happy), but it
  also silently dropped the null-files DATA protection ext4/xfs provide and
  generic/044-046 codify. Options upstream may prefer:
  a) kernel: keep file_extent_tree (or equivalent clamping) on NO_HOLES too;
  b) tests: declare null-files-after-crash acceptable on NO_HOLES and gate
     044-046 — that contradicts the tests' whole purpose (2015 Chinner,
     anti-null-files) and the ext4 auto_da_alloc precedent.
- Repro one-liner for the report: mkfs.btrfs (defaults) + mount -o commit=1
  + fstests generic/044 -> fails 15/15 on bare KVM.
- Check first whether linux-btrfs has discussed 044-on-no-holes before
  (lore was Anubis-blocked from here).

## Assets
- rootless-uml/t6-probe.sh (load fleet + per-boot isolation + image
  preservation; EXTRA env -> per-shard extra.config via shard-init hook)
- rootless-uml/t6-forensics.sh (dump-tree inode/extent extraction; NOTE its
  size-parsing awk is buggy — read dumps manually, see doc history)
- ~/uml-smoke/results/t6*/corrupt-*.img (9 corrupt images)
- ~/uml-smoke/results/qemu-044-commit1.out (the 15/15 KVM proof)
