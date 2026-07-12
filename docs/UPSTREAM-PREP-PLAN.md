# Upstream prep: understand & manually verify everything (2 evenings)

Goal: you can defend all five fstests patches under review questions, having
re-verified every claim with your own hands. No prior btrfs/xfstests knowledge
assumed. Each block has: background (short), a hands-on verification you run
yourself, and CHECKPOINT questions — if you can answer them without notes,
you're ready for that patch's review thread.

Conventions: run everything from `~/uml-smoke`. QEMU one-liners use our
rootless wrapper. `$XT` = `~/uml-smoke/xfstests-built`.

---

## Night 1 — foundations + the two "mechanical" patches (~3.5h)

### 1. btrfs mental model (25 min, reading only)
Read (in this order):
- https://btrfs.readthedocs.io/en/latest/Introduction.html
- https://btrfs.readthedocs.io/en/latest/ch-mount-options.html — just the
  entries for `max_inline`, `nodatasum`, `nodatacow`
- `docs/GENERIC-747-BTRFS-ENOSPC.md` §"Assessment" for chunks/DUP vocabulary

The five ideas you need: (a) copy-on-write: data is never overwritten in
place; (b) files are stored as EXTENTS; tiny files (≤ max_inline=2048) are
stored INLINE inside the metadata tree instead; (c) space is grouped into
CHUNKS dedicated to data or metadata; metadata defaults to DUP (two copies);
(d) deletions free space lazily (transaction commit / cleaner thread);
(e) `balance` rewrites chunks to compact them and can be paused/resumed.

### 2. xfstests anatomy, hands-on (40 min)
A test = shell script + "golden output". PASS = output matches golden file.
- Read `$XT/tests/btrfs/081` top to bottom (it's short). Note:
  `_begin_fstest` (groups), `_require_*` (skip conditions -> "notrun"),
  the golden file `081.out`, and that ANY stray output = failure.
- Run one test yourself on real x86:
    cd ~/uml-smoke && ./run-qemu.sh -enable-kvm -cpu host -m 4G -smp 4 \
      -kernel x86-mainline/arch/x86/boot/bzImage \
      -append "root=/dev/vda rw console=ttyS0 init=/qemu-init qtests=btrfs/081 panic=-1" \
      -drive file=qemu-rootfs.img,if=virtio,format=raw \
      -drive file=qemu-vdb.img,if=virtio,format=raw \
      -drive file=qemu-vdc.img,if=virtio,format=raw -nic none -nographic -no-reboot
- Find the result lines in the console output; identify pass/fail/notrun.

CHECKPOINT: What makes an fstests test fail? Where does a test's expected
output live? What does "notrun" mean and how is it different from "fail"?

### 3. the rig in one page (20 min)
Read `rootless-uml/README.md`, then skim `docs/STALL-TRIAGE-FINDINGS.md`
§"Profiling toolbox". Know just enough to answer "how was this tested":
- UML = the kernel compiled as a Linux userspace program — fast to boot,
  great for mass triage, but timing-distorted (fork-heavy tests run slow).
- QEMU/KVM = real x86 virtualization — slower to iterate, trustworthy.
- Our rule: nothing is claimed from UML alone; QEMU confirms everything.
  The cautionary tales: btrfs/301 (UML-only failure = artifact) and
  generic/044-046 (failed under UML load, 0/6 failures on real x86).

CHECKPOINT: Why do we test on both UML and QEMU? Give one example each of
a UML artifact and how it was caught.

### 4. Patch: btrfs/081 wait-noise (30 min)
Background: bash's `wait <pid>` prints "wait_for: No record of process" if
the child was already reaped (bash ≥5.2 behavior). That line lands in the
test's output -> golden mismatch -> false failure. The data-integrity part
of the test (md5 comparison) passed all along.
Verify yourself:
- `grep -n 'wait $reader_pid' $XT/tests/btrfs/081` and read 5 lines around.
- Reproduce the bash behavior in any shell:
    sleep 0.1 & p=$!; sleep 0.3; kill $p 2>/dev/null; wait $p; echo rc=$?
  (run it a few times; on bash 5.2 you can see the reaped-pid message class)
- Read the one-line patch: `rootless-uml/patches-xfstests/btrfs-081-wait-noise.patch`
CHECKPOINT: Why is `2>/dev/null` on this `wait` safe? (Answer: the test's
correctness signal is the md5 comparison + golden output, not wait's stderr;
the exit status is not consumed.)

### 5. Patch: btrfs/049 balance-pause races (60 min)
Background: the test needs a PAUSED balance (it verifies device-add works in
that state, then pause/resume again later). It starts a background balance
and immediately pauses — but a balance with little work COMPLETES before the
pause lands ("balance pause failed: Not running"). Our kernels finish
balance faster than the test author's, deterministically losing the race —
in TWO places in the test.
Verify yourself (manual race, in a scratch UML or QEMU shell):
- Boot the interactive checkenv-style guest OR simply re-run the test
  unpatched vs patched in QEMU:
    unpatched: git -C ~/uml-smoke/xfstests-built stash? — simpler: read
    `patches-xfstests/btrfs-049-balance-pause-race.patch` and map each hunk
    to the two `balance start --bg` + `balance pause` sites in the test.
- Run patched btrfs/049 in QEMU (qtests=btrfs/049) -> passes.
CHECKPOINT: What is the test actually trying to establish (device add is
allowed while balance is paused)? Why does retrying start+pause (adding
data between attempts) preserve that intent? Why is this a test bug and not
a kernel bug (a faster balance is not incorrect behavior)?

---

## Night 2 — the two deep patches + send mechanics (~4h)

### 6. fsverity + generic/574 + the guard + the btrfs/290 lesson (75 min)
Background, in order:
- fsverity = read-only file integrity: a Merkle tree over the file; any
  corrupted block must fail reads. Tests work by corrupting the raw device
  behind the fs's back, then expecting reads to error.
- The generic corruption helper `_fsv_scratch_corrupt_bytes` finds WHERE the
  file's bytes live via `fiemap` and dd's over them on the device.
- btrfs inline extents have NO fiemap-visible location (they live inside the
  metadata tree) -> the dd wrote to a meaningless offset -> NOTHING was
  corrupted -> reads "unexpectedly" succeeded -> test false-positived as a
  verity bypass. Only the block_size=1024 cases use files small enough.
Verify yourself, all three legs:
  a) see an inline extent with your own eyes (any btrfs mount, e.g. in the
     QEMU guest or a loop mount):
       xfs_io -f -c "pwrite 0 100" /mnt/scratch/tiny && sync
       xfs_io -r -c fiemap /mnt/scratch/tiny        # -> no extents printed
       # now with our option:
       mount -o remount,max_inline=0 /mnt/scratch (or fresh mount)
       ... repeat -> one real extent appears
  b) the false positive is kernel-independent: it reproduced identically on
     7.1-rc7 AND 7.2-rc1 on real x86 (docs/GENERIC-574-INVESTIGATION.md has
     the full matrix). Re-run if you want:
       qtests=generic/574 on x86-v71rc7 bzImage -> fails unpatched
  c) run patched: generic/574 AND btrfs/290 must BOTH pass —
       qtests=generic/574,btrfs/290 (rootfs tree already carries v2)
Read last: the Postscript in docs/GENERIC-574-INVESTIGATION.md — the v1
patch (global max_inline=0) broke btrfs/290, which corrupts inline extents
ON PURPOSE. v2 scopes the option to 574 and adds a loud guard to the helper.
CHECKPOINT: Why can't fiemap+dd corrupt an inline file? Why must the
max_inline=0 option NOT be global in common/verity? What does the new guard
do when a future test hands the helper an inline file, and why is failing
loudly correct?

### 7. generic/747 + btrfs space accounting (60 min)
Background: the test fills to 95% (by statfs), then races overwrites vs
deletes, asserting writes never ENOSPC. On btrfs it deterministically
ENOSPCs; on ext4 never. Two candidate explanations were eliminated by
instrumentation; make sure you can retrace that elimination:
- Reproduce with kernel-side evidence yourself (one command):
    qtests=generic/747 qmopts=-o,enospc_debug on x86-mainline, unpatched
    tree — but note our tree is already patched; to see the original
    failure use the archived console: results/qemu-747-debug.out
  Read the dump: `space_info DATA ... used==total, pinned=0`.
  pinned=0 == "nothing awaiting reclaim" == the kernel had ALREADY returned
  every deleted byte. So NOT a reclaim bug.
- The controller error: statfs `f_bavail` (see fs/btrfs/super.c
  btrfs_statfs) counts unallocated chunk space as available to data at
  factor 1, but DUP metadata growth consumes unallocated at 2x. As the test
  creates files, metadata grows, and "available" it counted evaporates.
  ext4 has no such dynamic — its statfs is exact — hence the control result.
- Run the patched test: qtests=generic/747 qloop=3 -> 3/3 pass.
CHECKPOINT: What does pinned=0 at the ENOSPC instant prove? Why does ext4
pass the identical test? Why is treating ENOSPC as "actually full -> take
the delete branch" faithful to a garbage-collection stress test's purpose?

### 8. verify the headline numbers (30 min)
- Run the smoke gate yourself: 
    KERNEL=~/uml-smoke/linux-for-next-0710/linux BASE=~/uml-smoke \
      bash ~/sources/btrfs-uml-fstests/rootless-uml/dev-check.sh smoke
  (expect ~23s, 20/20)
- Skim results/certification.out — map each line of the aggregate to what
  you now know: pass count, notrun (honest reasons), the solo-retry
  classifier's confirmed-vs-flaky split.

### 9. send mechanics + your own words (45 min)
- Read the fstests contribution norms: README in the xfstests repo
  (~ scratchpad clone: xfstests-up/README.md) — patch format, SoB line,
  list address fstests@vger.kernel.org; CC linux-btrfs for btrfs-touching
  patches; CC Eric Biggers for common/verity.
- THE UNDERSTANDING TEST: write the cover letter yourself, from memory,
  in your own words — one paragraph per patch: symptom, root cause, why
  this fix. If a paragraph is hard to write, revisit that block above.
- Then: git format-patch dry-run (I generate the series files; you edit
  the commit messages until they read as yours), git send-email setup
  (gmail app password), send patch 1 (081) alone first — smallest, safest
  way to calibrate list mechanics before the rest.

## Likely reviewer questions (rehearsal list)
- 081: "Why not fix the reader loop's trap instead?" (wait's stderr is
  noise either way; the trap is intentional; smallest change wins.)
- verity guard: "Should the helper _notrun instead of _fail?" (defensible
  either way — be ready to accept a v2 changing _fail->_notrun; the point
  is loud-not-silent.)
- 574: "Why not fix fiemap to report inline extents?" (kernel ABI question,
  decades of behavior; tests must work on existing kernels.)
- 049: "Why 5 retries?" (arbitrary bound; happy to make it 10/parametric —
  the principle is bounded retry with growing work.)
- 747: "Is btrfs statfs wrong then?" (long-standing known approximation;
  our patch makes the test robust to ANY fs whose statfs is approximate;
  we're not litigating statfs semantics.)
- Any: "What did you test this on?" (UML + QEMU/KVM x86, 7.1-rc7 and
  7.2-rc1 and btrfs for-next; full evidence chain in the repo docs.)
