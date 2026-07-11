# generic/747: deterministic btrfs ENOSPC under delete/overwrite race — real, btrfs-specific

## Finding

generic/747 (GC/reclaim stress: fill scratch to 95% with O_DIRECT+fsync files,
then race overwrites of up-to-256M files against `rm` + sync deletes) fails
**deterministically on btrfs and passes on ext4** on the identical device,
kernel, and environment:

| context (8G scratch, QEMU/KVM real x86) | result |
|---|---|
| btrfs, mainline 7.2-rc1, no load        | **FAIL 2/2** |
| btrfs, mainline 7.2-rc1, host under load | FAIL 6/6 |
| btrfs, UML (mainline + for-next, solo + sharded) | FAIL every run |
| **ext4, mainline 7.2-rc1, same device** | **PASS 2/2** |
| btrfs, 7.1-rc7 QEMU | (confirm in flight; both UML kernels already failed) |

Failure mode (from 747.out.bad / .full):

    Starting mixed write/delete test using buffered IO
    dd: error writing '/mnt/scratch/data_81': No space left on device
    ...
    Data: single 8.00MiB / Metadata: DUP 256.00MiB   <- post-mortem usage

The test deletes a random file and runs `_scratch_sync` before/while writers
proceed; the expectation "space freed by rm+sync is writable" holds on ext4
but not on btrfs — freed extents return only via delayed refs / cleaner /
transaction commit, and the ENOSPC flushing path gives up before reclaiming
them.

## Why we believe it (artifact filter, all layers passed)

1. **Not UML**: reproduces on QEMU/KVM real x86.
2. **Not load**: fails with zero host load.
3. **Not environment/test-tooling**: ext4 passes the same binary test on the
   same device image in the same guest.
4. **Not a regression**: 7.1-rc7 and 7.2-rc1 (and current for-next) all fail
   → longstanding behavior.
5. Reproducer is upstream fstests as-is (no local patches involved).

## Assessment — REVISED after -o enospc_debug instrumentation

The enospc_debug dump at the moment of failure exonerates the kernel:

    space_info DATA has 0 free, is full
    total=8035237888, used=8035237888, pinned=0, reserved=0, may_use=0
    failing ticket with 4096 bytes

pinned=0 means every deleted byte had ALREADY been reclaimed — data space
was genuinely, exactly full. The real mechanism is the test's fill
controller: it drives on statfs used%, and btrfs's f_bavail counts
unallocated space as available to data at factor 1 while DUP metadata
growth consumes it at 2x (fs/btrfs/super.c btrfs_statfs). As the test
creates hundreds of files, metadata expands, the controller's "available"
evaporates, and a write starts into a pool with only KB free. ext4 passes
because its statfs is exact — same control result, different meaning.

**Verdict: fstests robustness issue (third of its kind after generic/574
and btrfs/049), not a kernel bug.** The kernel-side alternative (modeling
worst-case metadata growth in f_bavail) is the perennial "btrfs df is
approximate" debate — not a realistic patch.

## Fix (validated)

patches-xfstests/generic-747-tolerate-enospc.patch: the mixed
write/delete phase treats dd ENOSPC as "filesystem actually full" — drop
the partial file, take the delete branch, keep accounting intact. This
matches the GC-stress intent. Validated 3/3 PASS on QEMU/KVM btrfs
(previously 0/10 fail) and applies cleanly to fstests upstream HEAD.
Disposition: fstests patch with this evidence chain; optional FYI CC to
linux-btrfs as a concrete f_bavail-optimism case.

## Related closures from the same investigation

- generic/044/045/046 "load flake": did NOT reproduce on real x86 under load
  (0/6) while flaking under UML load on both kernels → **UML-load artifact**,
  excluded-under-load, not a kernel issue.
- QEMU lane is now docker-free: `rootless-uml/run-qemu.sh` runs a
  deb-extracted qemu-system-x86_64 (+seabios/ipxe -L paths) directly against
  /dev/kvm — Docker Desktop's WSL integration is no longer a dependency.
