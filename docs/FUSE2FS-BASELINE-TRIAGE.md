# fuse2fs baseline — deep triage (2026-08-01)

**RESULT: baseline 35 -> 15.** Every entry classified; 20 recovered by rig
fixes in one session (fuse pin mainline-0724, fuse2fs 1.47.4). All 15
survivors are fuse/fuse2fs-semantics classes, none rig-fixable, several
upstream-worthy. Method: rerun the committed baseline on the current pin
(all 35 reproduced, 0 flaky), read every .out.bad, cluster by signature,
probe in-guest labs before touching anything (xfs playbook).

## Rig fixes applied (each verified by a full-list rerun)

1. **fuse2fs `-o kernel` mode** (mount.fuse.fuse2fs). Upstream's
   "behave like kernel ext4" switch: allow_other,default_permissions,
   suid,dev + ACL enforcement + permission checks deferred to the kernel.
   Our hand-rolled `allow_other,default_permissions` was a strict subset:
   no suid (generic/633), no dev (184, 434, part of 306), daemon-side
   perm checks blind to supplementary groups (683/684/685 fallocate
   EPERM).
2. **mount.fuse dispatcher** (new, shadows the stock mount.fuse ->
   mount.fuse3 symlink). Stock mount.fuse execs the mount SOURCE via
   /bin/sh — every `-t fuse` mount with a block device died with
   "/bin/sh: /dev/...: Permission denied": _get_mount -t $FSTYP
   (409/410/411/589) and all dm targets (338/347/441/484/500/743).
   Block-device source -> mount.fuse.fuse2fs, else stock behavior.
3. **Helper remount + same-superblock parity.** `-o remount` now does a
   real VFS remount (mount -i) instead of spawning a second fuse2fs that
   EBUSYs on the device (294/306/452 "Device or resource busy"); a mount
   of an already-mounted device becomes a bind from the first mountpoint
   + make-private (kernel filesystems share one superblock across
   mountpoints; propagation reset keeps 409/411 mount-table parity), which
   fixed 732 and the multi-mountpoint family.
4. **remember=-1** in the helper STD options: libfuse-highlevel forgets
   nodeids as soon as the kernel drops dentries, so open_by_handle decode
   ESTALEd even same-session; kernel filesystems never do that
   (probe-verified fix; recovered the plain-decode legs of 426-family).
5. **e2fsck + mke2fs 1.47.4** built and installed by build-fuse2fs.sh —
   judge and formatter were Ubuntu-stock 1.47.0, four minors behind the
   daemon under test (the xfs generic/753+754 stale-judging-binary trap).
6. **xfstests harness patches** (patches-xfstests/): _mkfs_dev fuse2fs
   branch (dm-target devices never got a filesystem — generic/347's
   "Bad magic number in super-block"); _check_fuse2fs_filesystem
   mountpoint fix (findmnt -t $FSTYP never matches type fuse.ext4, so the
   post-fsck remount silently didn't happen and generic/053's second ACL
   listing saw a bare mountpoint); generic/020 xattr sizing for
   ext4-backed fuse (max_attrs ~101/block and ~1-block values, not the
   generic 1000/64K).

## Remaining 15 — all confirmed-solo, classified

### A. File-handle decode after eviction/unlink — inherent-fuse (6)
generic/035, 426, 467, 477, 756, 777.
The FUSE protocol has no lookup-by-nodeid (no FUSE_EXPORT_SUPPORT in
libfuse-highlevel servers): open_by_handle_at can only decode a handle
whose inode is still in the kernel icache. remember=-1 fixed the
never-unlinked legs; what still fails is decode after the original name
is unlinked (426/467/756/777 `-u` legs; hardlink keeps the inode alive on
disk but not in the fuse icache) and across mount cycles (477, 777).
035 is the same family from the other side: fuse2fs frees the on-disk
inode at rename-over while a kernel fd still holds it open, so fstat
returns ESTALE where kernel filesystems keep the inode until last close.
Upstream angle: fstests could gate these on a "persistent file handles"
require for fuse; fuse2fs could defer inode reclaim to release (035).

### B. POSIX ACL <-> mode synchronization — fuse2fs upstream gap (4)
generic/099, 319, 375, 444.
ACLs are stored and enforced, but the mode-bit side of POSIX ACL
semantics is missing: setting an access ACL does not rewrite the group
permission bits (099 — probe: chacl set + readback fine, ls mode
unchanged, `+` marker present), and file creation under a default-ACL +
setgid directory derives group bits from umask instead of the ACL mask
(375/444 child `drwxr-sr-x` vs expected `drwxrwsr-x`; 319 default-ACL
propagation view). Kernel-side FUSE_POSIX_ACL only covers enforcement
and relies on the server for mode updates (fuse_set_acl does not do
posix_acl_update_mode). Upstream fuse2fs is actively reworking this area
post-1.47.4 (default-ACL propagation commits 2c79003876, 7fb6db6085,
sgid inheritance 33880eea11) — re-triage at the next e2fsprogs advance.

### C. Inode-flag enforcement on open fds — fuse2fs upstream BUGS (2)
generic/079, 553.
Source-level findings in fuse2fs (1.47.4, cross-checked against master):
- op_ftruncate has NO immutable/append-only check at all (079
  "ftruncate(append-only) did not fail") — still true in master.
- op_write has NO iflags re-check, and fuse2fs lacks copy_file_range, so
  the kernel falls back to read/write — writes to a file made immutable
  after open succeed (553) — still true in master.
- op_truncate (1.47.4 only) computes the EPERM but returns the wrong
  variable (`return err` where the check sets `ret`), so path truncate on
  immutable files silently no-ops "successfully" (079) — fixed in
  master's boilerplate rework, worth calling out for 1.47.x.
REPORT CANDIDATES for e2fsprogs (fuse2fs upstreaming is active — djwong's
2025 rework). KVM CROSSCHECK DONE 2026-08-01: qemu-init grew a fuse
branch (qfstyp=fuse -> FUSE_SUBTYP + ext4-nojournal mkfs; CONFIG_FUSE_FS
added to the x86 crosscheck kernel, build-x86.sh updated) and all 15
survivors were rerun under KVM (x86 mainline 7.2.0-rc1, virtio disks,
real page cache): generic/079 and 553 fail with IDENTICAL signatures
(same three "did not fail" lines; same missing copy_range EPERM) —
environment-independent, ready to send. Host-side repro remains blocked
for unprivileged mounts only (kernel denies SETFLAGS immutable without
privilege), irrelevant for the report.

### D. Writeback-error (errseq) propagation — fuse kernel semantics (2)
generic/441, 484.
dm-error mounts now work; what fails is error-reporting parity: a second
fd's fsync after a failed writeback doesn't see the error (441 "Success
on second fsync on fd[1]"), and syncfs doesn't return EIO (484). On
kernel filesystems errseq_t gives every fd one error report; the fuse
writeback path doesn't propagate this per-fd. Kernel-fuse territory
(fs/fuse writeback + FUSE_SYNCFS), not fuse2fs. KVM crosscheck
2026-08-01: 484 reproduces with the same signature ("One of the
following syncfs calls should fail with EIO") on mainline 7.2.0-rc1 —
not a UML artifact; 441 was inconclusive in the qemu lane (check aborts
on a duplicate /proc/mounts entry for the fuse TEST_DEV — qemu-lane
harness wrinkle, follow up before reporting 441 specifically).

### E. statx attribute flags — fuse protocol gap (1)
generic/424.
STATX_ATTR_{IMMUTABLE,APPEND,NODUMP,COMPRESSED} are not surfaced through
fuse getattr (flags live in the ext4 inode; the protocol doesn't carry
them). Inherent until the fuse statx extension grows attribute support;
fstests could _require statx attr support instead of assuming it.

## Judgement-toolchain note
e2fsck/mke2fs/fuse2fs now all pinned at E2FSPROGS_VER=1.47.4 (was: daemon
1.47.4, judge+formatter 1.47.0). No verdict changed after the upgrade
(the 347 "inconsistent" was a genuinely absent filesystem), but the skew
class is closed.

## History
- 2026-08-01 deep triage: 35 -> 15 (this document).
- 2026-07-25 sweep #9 on per-fs pin: 35 confirmed (generic/410 folded).
- 2026-07-17 canonical baseline (sweep-8): 206 pass / 549 notrun / 34+2
  load-flaky. Original sweep-6 triage and the five-aborted-sweeps rig
  ledger: see git history of this file (clusters were: fsx zero-range —
  fixed via fuse2fs 1.47.4 upgrade; ro-mount family, helper bypass,
  fallocate EPERM — all rig-fixed today; open_by_handle — cluster A).
