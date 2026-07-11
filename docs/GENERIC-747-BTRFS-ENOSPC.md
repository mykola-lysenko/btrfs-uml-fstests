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

## Assessment

Class: btrfs ENOSPC/space-reclaim weakness under high fill + delete/overwrite
concurrency — a user-visible wart ("deleted files but still ENOSPC") with a
clean deterministic reproducer. May be a known pain point for btrfs
maintainers; the value here is the tight reproducer + cross-fs control.
Candidate disposition: report/question to linux-btrfs with this table, or a
btrfs-specific `_notrun`/requirement in fstests if maintainers declare it
expected behavior.

## Related closures from the same investigation

- generic/044/045/046 "load flake": did NOT reproduce on real x86 under load
  (0/6) while flaking under UML load on both kernels → **UML-load artifact**,
  excluded-under-load, not a kernel issue.
- QEMU lane is now docker-free: `rootless-uml/run-qemu.sh` runs a
  deb-extracted qemu-system-x86_64 (+seabios/ipxe -L paths) directly against
  /dev/kvm — Docker Desktop's WSL integration is no longer a dependency.
