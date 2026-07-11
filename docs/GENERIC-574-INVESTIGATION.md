# generic/574: apparent fsverity bypass on btrfs — root-caused to an fstests bug

## Symptom

Once today's environment unlocks let generic/574 (fsverity corruption
detection) run for the first time, it failed on btrfs: at
`block_size=1024`, corrupted files were readable via buffered reads, DIO,
and mmap with no verity error. At face value: an integrity hole
(security-relevant) — fsverity serving corrupted data.

## Cross-check trail (the artifact filter at work)

| experiment | result |
|---|---|
| UML, 7.2-rc1 | FAIL (1024 section) |
| QEMU/KVM real x86, 7.2-rc1 | FAIL — identical, so NOT a UML artifact |
| QEMU/KVM real x86, 7.1-rc7 | FAIL — not a 7.1→7.2 regression |
| QEMU/KVM, 7.2-rc1, `-o max_inline=0` | **PASS — kernel exonerated** |

## Root cause (fstests, not kernel)

The failing cases are exactly `file_len=1024/2048` — files small enough for
btrfs **inline extents** (default `max_inline=2048`). For data corruption
(`is_merkle_tree=false`) the test uses `_fsv_scratch_corrupt_bytes`, which
locates file data via **fiemap** and `dd`s over it on the raw device.
Inline extents expose no usable physical address via fiemap, so the dd
lands on a meaningless device offset: **no corruption ever happens**.
Confirmed by dmesg: zero btrfs csum/correction events during the "corrupt
then read" sequence. The file then reads back its original, correct data
and the test misreports "Unexpectedly was able to read ..." as a verity
failure.

The 4096-block section passes only because its file sizes exceed
`max_inline`, producing real (corruptible) data extents.

## Fix (upstream candidate)

`common/verity` already forces `-o nodatasum` for btrfs so btrfs's own
data checksums don't mask verity. Extend the same block with
`max_inline=0` so verity test files always get real data extents:

    patches-xfstests/verity-btrfs-max-inline.patch

Validated: generic/574 passes with the fix on UML and on QEMU/KVM
(7.2-rc1), all sections including block_size=1024.

## Kernel-side note (worth an upstream question, not a bug report)

`fs/btrfs/inode.c:read_inline_extent()` fills folios with no
`fsverity_verify_*` call — inline data is only protected by metadata
checksums (crc32c), not by the verity Merkle tree. With `nodatasum`
mounts this is fine (metadata csums still apply), and a malicious-image
scenario is outside fsverity's original threat model on btrfs, but the
asymmetry (verity-enabled file whose first 2048 bytes are never
Merkle-verified at read time) may interest btrfs/fsverity maintainers.

## Meta

This is the second finding killed by the cross-check pipeline before an
embarrassing upstream report (first: btrfs/301, a UML artifact). Pipeline:
UML triage → QEMU confirm → version A/B → hypothesis experiment
(`max_inline=0`) → verdict. Total cost: ~4 QEMU boots.
