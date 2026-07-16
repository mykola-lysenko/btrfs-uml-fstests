# Draft: NO_HOLES null-files report for linux-btrfs

**To:** linux-btrfs@vger.kernel.org
**Cc:** josef@toxicpanda.com (file_extent_tree author), fdmanana@suse.com
(prior no-holes/disk_i_size fixes), dsterba@suse.com, wqu@suse.com, clm@fb.com
**Optional Cc:** fstests@vger.kernel.org, zlang@kernel.org — only if we lead
with "should generic/044-046 be gated"; NOT recommended (see framing note).
**Subject:** NO_HOLES: buffered write + same-size truncate can commit i_size
without data — files full of zeroes after crash (generic/044-046)

**Framing decision (ours):** report-first, no patch attached. Unlike the two
raid56 patches, the fix here reverses a deliberate design choice in
41a2ee75aab0 (skip the per-inode file extent tree on NO_HOLES), so the
maintainers should pick the mechanism. We state a recommendation and offer
to test/write the patch.

---

Hello,

Note 1: I found and reproduced this problem using AI tools.
Note 2: "UML" below refers to User Mode Linux guests driven by
https://github.com/mykola-lysenko/btrfs-uml-fstests (mass-parallel fstests
rig); every claim was re-verified on real x86-64 under KVM.

Summary
-------
On filesystems with the NO_HOLES incompat flag (the mkfs.btrfs default
since btrfs-progs 5.15), the protection that keeps the committed i_size
from outrunning committed data is absent, so a buffered write followed by
a same-size truncate can persist "size=N, nbytes=0, no extent items" at
the next transaction commit. After a crash/shutdown before writeback
commits, the file reads back as N bytes of zeroes. The image is fsck-clean
(NO_HOLES makes the implicit hole legal metadata), so nothing ever flags
it — except fstests generic/044-046, which exist to codify exactly this
anti-null-files guarantee and which ext4, xfs, and btrfs without NO_HOLES
all provide.

Deterministic reproducer (real hardware, no UML needed)
-------------------------------------------------------
    mkfs.btrfs (defaults)          # NO_HOLES on by default since progs 5.15
    mount -o commit=1
    fstests generic/044            # fails 15/15 on bare-metal KVM x86-64

`-o commit=1` is only a determinism lever: it forces a transaction commit
into the window between truncate and delalloc writeback that the test's
loop otherwise straddles only on slow or loaded machines. With the default
30s commit interval the whole test usually fits inside one interval and
the bug hides — which is presumably why 044-046 have not been reported
against NO_HOLES before (we found no prior lore thread).

Mechanism
---------
1. generic/044 does `pwrite 0 64k` (buffered, no fsync) then
   `truncate 64k` (same size). btrfs_setsize() routes newsize == oldsize
   into the shrink path, reaching btrfs_truncate() ->
   btrfs_inode_safe_disk_i_size_write().
2. btrfs_inode_safe_disk_i_size_write() is the guard that clamps
   disk_i_size to the contiguous-from-offset-0 range of COMMITTED extents
   — but only via inode->file_extent_tree, and
   btrfs_init_file_extent_tree() skips allocating that tree when the fs
   has NO_HOLES. With the tree NULL the function sets
   disk_i_size = i_size unconditionally.
3. If a transaction commit lands between the truncate and delalloc
   writeback, the inode item is committed with size=65536, nbytes=0 and
   zero EXTENT_DATA items (verified with btrfs inspect-internal dump-tree
   on preserved images). A crash before the next commit yields the
   64KiB file of zeroes. btrfs check reports no error.

Evidence matrix (single-variable toggle)
----------------------------------------
    platform                mkfs              mount          generic/044
    KVM x86-64, idle        defaults          -o commit=1    15/15 fail
    UML, 10-guest load      defaults          -o commit=1     8/8  fail
    UML, 10-guest load      -O ^no-holes      -o commit=1     0/8  fail
    UML, 10-guest load      defaults          defaults        1/10 fail

Reproduced on mainline 7.2-rc1 and btrfs for-next (2026-07-10); the
mechanism is present since the file_extent_tree was introduced.

Why we think this is a kernel gap rather than a test gap
--------------------------------------------------------
- The comment above btrfs_inode_safe_disk_i_size_write() justifies the
  NO_HOLES shortcut purely on metadata validity ("perfectly fine with a
  file that has holes without hole file extent items"). That is true, but
  the clamp was never only about representability — it is what prevents
  committed size from outrunning committed data, i.e. the null-files
  guarantee that generic/044-046 encode (and that ext4 provides via
  auto_da_alloc since the 2009 delalloc null-files episode).
- There is precedent for treating this class as data loss on NO_HOLES:
  76b42abbf748 ("Btrfs: fix data loss after truncate when using the
  no-holes feature") and e7db9e5c6b96 ("btrfs: fix encoded write i_size
  corruption with no-holes") both fixed bugs in this area; the latter
  patched btrfs_inode_safe_disk_i_size_write() itself, carries
  Fixes: 41a2ee75aab0 and went to stable 5.10+ — i.e. the NO_HOLES
  disk_i_size shortcut has already produced stable-worthy corruption
  once.
- The alternative — declaring null files after crash acceptable on
  NO_HOLES and gating 044-046 — would silently regress the default-mkfs
  crash semantics relative to every other major fs, via a flag most users
  never chose explicitly.

Possible directions (maintainers' call)
---------------------------------------
a) Allocate the file_extent_tree (or an equivalent committed-data bound)
   on NO_HOLES filesystems too, restoring the clamp. Cost: one small
   per-inode allocation — exactly what the skip was avoiding.
b) A cheaper NO_HOLES-specific rule, e.g. do not advance disk_i_size past
   the ordered-extent frontier for inodes with outstanding delalloc.
c) Decide the behavior is acceptable and gate the tests (we would argue
   against, per above).

We are happy to test patches on the rig (the reproducer is deterministic)
or to draft option (a) if that is the preferred shape.

## Send procedure (when ready)

    git send-email \
      --to=linux-btrfs@vger.kernel.org \
      --cc=josef@toxicpanda.com --cc=fdmanana@suse.com \
      --cc=dsterba@suse.com --cc=wqu@suse.com --cc=clm@fb.com \
      <plain-text version of the body above>

(No patch file — send as a plain report mail, e.g. via the Gmail draft.)

## Open items before sending
1. ~~progs version~~ VERIFIED 2026-07-16: btrfs-progs 5.15 (Nov 2021),
   changelog: "mkfs: new defaults! no-holes".
2. Optionally re-run the 0/8 ^no-holes arm once more on for-next to have
   a same-kernel A/B pair in the mail (current arms span two builds).
   ~1h rig time; the mail is defensible without it.
3. ~~Boris hash~~ VERIFIED 2026-07-16: e7db9e5c6b96, touches
   fs/btrfs/file-item.c, Fixes: 41a2ee75aab0, CC stable 5.10+,
   landed v6.4-rc2.
