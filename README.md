# BTRFS fstests on User Mode Linux (UML)

A complete toolkit for running [fstests](https://git.kernel.org/pub/scm/fs/xfs/xfstests-dev.git) against BTRFS inside [User Mode Linux](https://docs.kernel.org/virt/uml/user_mode_linux_howto_v2.html) — enabling fast, isolated, parallel filesystem regression testing without requiring root, KVM, or dedicated hardware.

## Motivation

Running fstests on bare-metal or in KVM is slow and resource-intensive. UML runs the Linux kernel as a plain userspace process, making it ideal for CI environments. This project identifies which fstests are compatible with UML, provides tooling to build the environment from scratch, and implements parallel sharding with in-memory block devices to maximize throughput.

## Repository Structure

```
btrfs-uml-fstests/
├── README.md                        # This file
├── scripts/
│   ├── setup-uml-env.sh             # End-to-end environment setup (idempotent)
│   └── run-uml-parallel.sh          # Parallel sharded test runner
├── configs/
│   ├── kernel.config.fragments      # Kernel config fragments for UML+BTRFS
│   └── local.config.template        # fstests local.config template
├── docs/
│   ├── btrfs_uml_fstests_plan.md    # Test compatibility analysis and plan
│   ├── fstests_speedup_strategies.md # Speed-up strategies and benchmarks
│   ├── tmpfs_downsides_analysis.md  # Downsides of in-memory block devices
│   └── README-parallel-runner.md   # Parallel runner detailed documentation
└── results/                         # Test results (populated after runs)
    └── .gitkeep
```

## Quick Start

### 1. Build the Environment

```bash
# Install deps, download Linux 6.19.x, build UML kernel, create rootfs
bash scripts/setup-uml-env.sh
```

This script is **idempotent** — it skips steps already completed. On a 6-core machine it takes approximately 15 minutes on first run.

### 2. Run Tests in Parallel (Recommended)

```bash
# Run all compatible tests across 3 parallel UML shards with RAM-backed images
bash scripts/run-uml-parallel.sh \
  --shards 3 \
  --uml-binary ~/linux-6.19.9/linux \
  --rootfs ~/rootfs.img \
  --test-list ~/uml_all_auto_tests.txt \
  --results-dir ~/results \
  --uml-mem 512M \
  --tmpfs-dir /dev/shm
```

### 3. Run Quick Tests Only (Fast CI)

```bash
# Only 'quick' tagged tests — completes in ~60 minutes on 3 shards
bash scripts/run-uml-parallel.sh \
  --shards 3 \
  --uml-binary ~/linux-6.19.9/linux \
  --rootfs ~/rootfs.img \
  --test-list ~/uml_quick_tests.txt \
  --results-dir ~/results/quick \
  --uml-mem 512M \
  --tmpfs-dir /dev/shm
```

## Test Compatibility

Out of the full fstests suite, the following are compatible with UML (no device mapper, no multi-device RAID, no crash injection):

| Category | Quick tests | Auto tests | Total |
|---|---|---|---|
| `btrfs/` specific | ~193 | ~26 | ~219 |
| `generic/` (BTRFS-compatible) | ~279 | ~82 | ~361 |
| **Total** | **~472** | **~108** | **~580** |

Tests excluded from UML runs require:
- `dm-flakey` / `dm-log-writes` (crash/power-fail simulation)
- `SCRATCH_DEV_POOL` (multi-device BTRFS RAID volumes)
- `_require_realtime` (real-time device support)

See [`docs/btrfs_uml_fstests_plan.md`](docs/btrfs_uml_fstests_plan.md) for the full analysis.

## Performance

Observed on a 6-core host with 4GB RAM running Linux 6.19.9:

| Mode | Tests in 30 min | Estimated total time |
|---|---|---|
| Sequential, disk-backed | ~3–5 | ~8–10 hours |
| Sequential, tmpfs-backed | ~8–12 | ~3–4 hours |
| **3-shard parallel, tmpfs** | **~18–25** | **~90–120 min** |

The key bottleneck is a handful of heavy `fsstress` tests (`btrfs/002`, `btrfs/004`, `btrfs/010`) that each take 15–30 minutes. Sharding distributes these across parallel instances, preventing them from serializing the entire run.

## Kernel Configuration

The UML kernel is built with the following BTRFS-relevant options enabled:

```
CONFIG_BTRFS_FS=y
CONFIG_BTRFS_FS_POSIX_ACL=y
CONFIG_BTRFS_FS_CHECK_INTEGRITY=y
CONFIG_BTRFS_DEBUG=y
CONFIG_BTRFS_ASSERT=y
CONFIG_BTRFS_FS_REF_VERIFY=y
CONFIG_BTRFS_FS_RUN_SANITY_TESTS=y
CONFIG_FS_VERITY=y
CONFIG_FSCRYPT=y
CONFIG_QUOTA=y
CONFIG_CRYPTO_XXHASH=y
CONFIG_CRYPTO_BLAKE2B=y
CONFIG_CRYPTO_ZSTD=y
```

## Downsides of In-Memory Block Devices

Using `/dev/shm`-backed images significantly speeds up I/O but has important caveats for test fidelity. See [`docs/tmpfs_downsides_analysis.md`](docs/tmpfs_downsides_analysis.md) for the full analysis. The key concern is that crash-consistency and power-fail recovery tests are meaningless on volatile RAM-backed devices — these should be run periodically on persistent storage.

## Requirements

- Linux host (x86_64)
- `sudo` privileges (for `debootstrap` and loop mounts)
- ~15 GB free disk space (kernel source + rootfs + images)
- ~4 GB RAM minimum (8 GB recommended for 3+ shards)
- Tools: `git`, `gcc`, `make`, `debootstrap`, `btrfs-progs`, `e2fsprogs`

## License

Scripts and documentation in this repository are released under the [GPL-2.0 License](https://www.gnu.org/licenses/old-licenses/gpl-2.0.en.html), consistent with the Linux kernel and fstests projects.
