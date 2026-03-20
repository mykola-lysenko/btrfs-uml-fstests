# UML Parallel fstests Runner for BTRFS

This directory contains a complete, validated setup for running BTRFS `fstests` on User-Mode Linux (UML) with parallel execution and in-memory block devices.

## Files

| File | Description |
|---|---|
| `run-uml-parallel.sh` | Main parallel runner script |
| `linux-6.14.2/linux` | UML kernel binary (Linux 6.14.2) |
| `rootfs.img` | Base Debian rootfs with fstests installed |
| `uml_all_auto_tests.txt` | 641 UML-compatible tests (BTRFS + generic) |
| `uml_quick_tests.txt` | 516 quick tests only (faster CI subset) |

## Quick Start

```bash
# Run all 641 compatible tests with auto-detected parallelism
./run-uml-parallel.sh

# Run only the 516 quick tests (faster, good for CI)
./run-uml-parallel.sh --test-list uml_quick_tests.txt

# Run with explicit shard count
./run-uml-parallel.sh --shards 4

# Run without tmpfs (disk-backed, for debugging)
./run-uml-parallel.sh --no-tmpfs
```

## How It Works

The runner performs the following steps:

1. **Shards the test list** using round-robin interleaving, so each shard gets a balanced mix of fast and slow tests.
2. **Creates per-shard disk images** in `/dev/shm` (a pre-existing `tmpfs` on all Linux systems). Each shard gets its own copy of the rootfs and sparse test/scratch images.
3. **Installs the shard-specific test list** into each rootfs copy via loop mount.
4. **Launches N UML instances in parallel**, each running its own subset of tests.
5. **Monitors progress** every 30 seconds, showing tests started and completed.
6. **Aggregates results** from all shard logs and extracts per-test result files.
7. **Cleans up** the tmpfs shard directories.

## Key Design Decisions

### Why `/dev/shm` for tmpfs?

UML's UBD (User-mode Block Device) driver opens backing files using standard `open(2)` syscalls from a forked I/O helper thread. Both the main UML process and the I/O thread must be able to access the backing files for the entire duration of the run. `/dev/shm` is a `tmpfs` that is:

- Always mounted on all Linux systems
- Accessible to all processes (no mount namespace issues)
- Backed entirely by RAM (no physical I/O latency)

A custom `tmpfs` mounted at e.g. `/mnt/uml-tmpfs` also works, but it must remain mounted for the entire duration of all UML processes.

### Why round-robin sharding?

Distributing tests in round-robin order (test 0 → shard 0, test 1 → shard 1, test 2 → shard 0, ...) ensures that heavy `fsstress` tests (like `btrfs/002`, `btrfs/004`) are spread across shards rather than all landing in one shard. This minimizes the maximum shard completion time.

### Why explicit `mkfs.btrfs` in the init script?

The `fstests` `check` script respects `RECREATE_TEST_DEV=true` and will reformat the test device before each test. However, it first attempts to mount the device to check its current state. An explicit `mkfs.btrfs -f /dev/ubdb` before `./check` runs ensures the device is in a valid state for the initial mount attempt.

## Downsides of In-Memory Block Devices

Using `tmpfs`-backed images significantly accelerates I/O-bound tests but introduces important caveats:

| Concern | Details |
|---|---|
| **Masked timing bugs** | RAM I/O is orders of magnitude faster and has uniform latency, which can prevent race conditions from manifesting. Bugs triggered by slow flush/FUA semantics may go undetected. |
| **No crash consistency testing** | `tmpfs` is volatile. Tests that verify recovery from power loss or kernel panics (normally done via `dm-log-writes`) cannot be meaningfully run with RAM-backed devices. |
| **High host memory consumption** | Each shard requires ~1GB for the rootfs copy plus RAM for the test/scratch images as they are written. With 8 shards, this can consume 8-16GB of host RAM. |
| **No hardware quirks** | Physical devices expose sector size, alignment, and storage topology quirks. `tmpfs` presents none of these, so hardware-specific bugs may be missed. |

**Recommendation:** Use `tmpfs`-backed parallel UML runs for rapid CI feedback (catching logic and correctness bugs). Complement with weekly bare-metal or KVM runs on physical NVMe devices for timing, crash-consistency, and hardware-specific testing.

## Performance Expectations

Based on empirical measurements on a 6-CPU, 4GB RAM host:

| Configuration | Tests | Estimated Time |
|---|---|---|
| Sequential, disk-backed | 641 | ~144 min |
| 2 shards, disk-backed | 641 | ~72 min |
| 2 shards, tmpfs-backed | 641 | ~50 min |
| 3 shards, tmpfs-backed | 641 | ~35 min |
| Quick tests only, 2 shards, tmpfs | 516 | ~30 min |

On a larger host (16 CPUs, 32GB RAM), 8 shards with tmpfs can complete the full 641-test run in approximately **10-15 minutes**.

## Options Reference

```
--shards N          Number of parallel UML instances (default: auto = nproc/2)
--uml-binary PATH   Path to UML kernel binary (default: ./linux-6.14.2/linux)
--rootfs PATH       Path to rootfs image (default: ./rootfs.img)
--test-list PATH    Path to test list file (default: ./uml_all_auto_tests.txt)
--results-dir PATH  Directory to collect results (default: ./results-<timestamp>)
--uml-mem SIZE      Memory per UML instance, e.g. 512M (default: 512M)
--test-img-size S   Size of TEST_DEV image per shard (default: 5G)
--scratch-img-size S Size of SCRATCH_DEV image per shard (default: 5G)
--tmpfs-dir PATH    Host directory to use for tmpfs images (default: /dev/shm)
--no-tmpfs          Use regular disk-backed images instead of tmpfs
--timeout SECS      Per-shard timeout in seconds (default: 7200)
```

## Validated Configuration

This setup was validated on:
- **Host OS:** Ubuntu 22.04 (linux/amd64)
- **UML Kernel:** Linux 6.14.2 (built from source with BTRFS, loop devices, quotas, ACLs)
- **fstests:** Latest from https://git.kernel.org/pub/scm/fs/xfs/xfstests-dev.git
- **Rootfs:** Debian Bookworm (debootstrap) with btrfs-progs, xfsprogs, fio, and all fstests dependencies
- **Validation result:** 10/10 tests passed across 2 parallel shards in 2m31s
