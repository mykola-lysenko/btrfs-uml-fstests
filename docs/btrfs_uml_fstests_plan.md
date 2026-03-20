# Plan for Running BTRFS fstests on User Mode Linux (UML)

**Author:** Manus AI

## 1. Introduction

User Mode Linux (UML) is a virtualization system that runs a Linux kernel as a standard user-space process [1]. Because it intercepts system calls rather than emulating hardware, it offers an extremely lightweight environment that can boot rapidly and run without specialized CPU virtualization features. This makes it an attractive target for running filesystem test suites like `fstests` to accelerate test execution.

However, UML is 100% paravirtualized [1]. Its block devices (UBD) map to host files, and it does not emulate real hardware buses (like PCI). While UML can effectively test pure filesystem logic, it cannot support tests that rely on hardware-specific features, multi-device block layer topologies, or advanced device mapper configurations.

This document analyzes the `fstests` suite for BTRFS and outlines a strategic plan for selecting the optimal tests to run in a UML environment.

## 2. UML Capabilities and Limitations

Before categorizing the tests, it is essential to understand what UML can and cannot support regarding filesystem testing.

### Supported Features
*   **Basic Block I/O:** The User Block Device (UBD) driver allows mapping host files as virtual block devices (`/dev/ubda`, `/dev/ubdb`, etc.) [1].
*   **Copy-on-Write (COW):** UBD natively supports COW files, allowing multiple UML instances to share a base image while writing changes to a separate file [1].
*   **TRIM/Discard:** As of kernel 4.19, UML fully supports TRIM operations on UBD devices, meaning tests requiring `_require_fstrim` or `_require_batched_discard` will function correctly [1].
*   **Loop Devices:** Loopback devices are supported provided `CONFIG_BLK_DEV_LOOP` is enabled in the UML kernel configuration [2].

### Critical Limitations
*   **Multiple Block Devices (RAID):** While UML can mount multiple UBD devices, `fstests` heavily relies on the `SCRATCH_DEV_POOL` variable for BTRFS RAID and multi-device volume testing. Managing dynamic device pools and simulating physical disk failures across multiple virtual disks is highly unreliable in UML.
*   **Device Mapper (Fault Injection):** Many BTRFS consistency tests use Device Mapper targets like `dm-flakey` or `dm-log-writes` to simulate power failures, write ordering issues, and block layer errors [3]. While UML can technically compile Device Mapper support, configuring and reliably triggering these targets against UBD devices in a paravirtualized environment often leads to hangs or unsupported operations.
*   **Zoned Block Devices:** UML does not emulate SMR/ZNS drives. Tests requiring `_require_zoned_device` cannot be executed.
*   **Uniprocessor Architecture:** UML is strictly uniprocessor [1]. While it can spin up helper threads for I/O, the kernel itself runs on a single virtual CPU. Heavy concurrency stress tests may not yield realistic race condition scenarios and run significantly slower due to context switching overhead.

## 3. Analysis of BTRFS fstests

The `fstests` suite contains 342 tests specifically for BTRFS (`tests/btrfs/*`) and 787 generic tests (`tests/generic/*`) [3]. Tests are categorized using tags (e.g., `auto`, `quick`, `stress`, `dangerous`) and enforce hardware dependencies via `_require_*` functions [4].

Based on a programmatic analysis of the `fstests` repository, we have categorized the BTRFS-specific tests into four tiers for UML compatibility.

### Tier 1: Ideal for UML (193 tests)
These tests run quickly, are part of the standard `auto` group, and have no hardware dependencies that conflict with UML. They focus on core BTRFS features like snapshots, subvolumes, send/receive, and cloning.

*   **Key Features Tested:** `send` (77 tests), `compress` (34 tests), `clone` (34 tests), `snapshot` (26 tests), `qgroup` (24 tests), `subvol` (20 tests).
*   **Examples:** `btrfs/001` (subvol/snapshot), `btrfs/008` (send), `btrfs/024` (compress).
*   **Recommendation:** Run these on every commit. They provide the highest value-to-time ratio in a UML environment.

### Tier 2: Good for UML (26 tests)
These tests are UML-compatible but lack the `quick` tag. They perform deeper consistency checks, longer balances, or more extensive quota limit testing.

*   **Key Features Tested:** `qgroup` (8 tests), `balance` (6 tests), `snapshot` (4 tests).
*   **Examples:** `btrfs/012` (convert), `btrfs/028` (qgroup balance).
*   **Recommendation:** Run these nightly or before major pull requests. They will run fine in UML but take longer to complete.

### Tier 3: Caution / Stress (6 tests)
These tests do not require special hardware but are tagged as `dangerous` or `stress`. They are designed to intentionally crash the system or push it to extreme limits (e.g., OOM scenarios).

*   **Examples:** `btrfs/179` (qgroup dangerous), `btrfs/212` (balance dangerous), `btrfs/252` (send balance stress).
*   **Recommendation:** Run these in isolated UML instances. Because UML is a user-space process, a kernel crash inside UML will not take down the host [1], making UML an excellent, safe sandbox for these tests. However, due to UML's uniprocessor nature, stress tests may take excessively long.

### Tier 4: Not Suitable for UML (117 tests)
These tests are blocked by hardware or infrastructure requirements that UML cannot reliably provide.

| Blocker Requirement | Count | Reason for Exclusion in UML |
| :--- | :--- | :--- |
| `_require_scratch_dev_pool` | 88 | Requires multiple physical block devices for RAID/volume testing. |
| `_require_dm_target` | 28 | Requires `dm-flakey`, `dm-error`, or `dm-thin` for crash simulation. |
| `_require_btrfs_forget_or_module_loadable` | 10 | Requires unloading/reloading the BTRFS kernel module, which is complex in monolithic UML builds. |
| `_require_log_writes` | 6 | Requires `dm-log-writes` for write ordering fault injection. |
| `_require_zoned_device` | 4 | Requires SMR/ZNS drive emulation. |
| `_require_fail_make_request` | 3 | Block layer error injection not supported by UBD. |

*Note: Some tests have multiple blockers, so the total exceeds 117.*

### Generic Tests Compatibility
Out of the 787 generic tests, 277 are strictly for XFS. Of the remaining tests, **427 are UML-friendly** (no DM targets, no multi-device pools).
*   **Tier 1 Generic (Quick + Auto):** 324 tests.
*   **Tier 2 Generic (Auto only):** 99 tests.
*   **Top Features:** `clone` (79 tests), `rw` (73 tests), `mmap` (36 tests), `metadata` (32 tests).

## 4. Execution Plan for UML

To speed up `fstests` execution using UML, we recommend implementing a stratified testing pipeline.

### Phase 1: Fast Feedback Loop (Per-Commit)
Create a test runner configuration that executes only Tier 1 BTRFS tests and Tier 1 Generic tests.
*   **Scope:** ~193 BTRFS tests + ~324 Generic tests.
*   **Setup:** 
    *   Single UML instance.
    *   2 virtual CPUs (UML is uniprocessor, but extra threads help with UBD I/O).
    *   2GB RAM (`mem=2048M`).
    *   One `TEST_DEV` (UBD image, 10GB) and one `SCRATCH_DEV` (UBD image, 10GB).
*   **Expected Runtime:** Under 30 minutes.

### Phase 2: Deep Consistency Loop (Nightly)
Execute Tier 2 tests and fsstress-based tests that do not require Device Mapper.
*   **Scope:** ~26 BTRFS Tier 2 tests + ~99 Generic Tier 2 tests + 13 UML-compatible `fsstress` tests.
*   **Setup:** Same as Phase 1.
*   **Expected Runtime:** 1-2 hours.

### Phase 3: Dangerous/Crash Loop (On-Demand)
Run the `dangerous` tagged tests in isolated, disposable UML instances.
*   **Scope:** 6 BTRFS dangerous tests.
*   **Setup:** Ephemeral UML instances that are automatically killed and restarted if the test induces a kernel panic.

### Tests to Offload to Bare Metal/KVM
The 117 Tier 4 BTRFS tests (RAID, Device Mapper, Zoned devices) **must** remain on traditional KVM virtual machines or bare-metal hardware. UML should not be used for these, as the paravirtualized block layer will either fail the test requirements or produce invalid results.

## 5. Summary

User Mode Linux is an excellent tool for accelerating the execution of pure filesystem logic tests. By filtering out tests that rely on multi-device topologies (`SCRATCH_DEV_POOL`) and block-layer fault injection (`dm-flakey`), developers can run approximately **56% of BTRFS-specific tests** and **54% of generic tests** in a lightweight, rapid UML environment. This strategy significantly reduces the feedback loop for core BTRFS features like send/receive, subvolumes, qgroups, and cloning.

## References

[1] The Linux Kernel Documentation. "UML HowTo." https://docs.kernel.org/virt/uml/user_mode_linux_howto_v2.html
[2] Cateee.net. "CONFIG_BLK_DEV_LOOP: Loopback device support." https://cateee.net/lkddb/web-lkddb/BLK_DEV_LOOP.html
[3] kdave/xfstests GitHub Repository. https://github.com/kdave/xfstests
[4] LWN.net. "Best practices for fstests." https://lwn.net/Articles/897061/
