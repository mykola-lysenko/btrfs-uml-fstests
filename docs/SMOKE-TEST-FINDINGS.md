# UML btrfs smoke tests — empirical findings

Date: 2026-07-01. Host: 32 cores, 15 GiB RAM, WSL2, no passwordless sudo.

Goal: characterize the UML smoke-test path — speed, coverage, gaps, and how to
(a) speed up and (b) cover more features.

## TL;DR

- The existing repo's `setup-uml-env.sh` **cannot run here** — it needs
  passwordless `sudo` (debootstrap, apt, loop mounts) and downloads the kernel
  from `cdn.kernel.org`, which is blocked in this sandbox.
- I built a **fully rootless** UML btrfs harness instead (no sudo anywhere) and
  ran real smoke tests. It works and is *fast*.
- Two of the repo's stated UML limitations are **false**: multi-device/RAID works,
  and device-mapper (dm-flakey / dm-log-writes → crash-consistency tests) works.

## How the rootless harness was built (no sudo)

1. Kernel source: `codeload.github.com/torvalds/linux/tar.gz/refs/tags/v6.12`
   (cdn.kernel.org is blocked; git.kernel.org cgit snapshots time out). 201 MB.
2. Build: `make ARCH=um defconfig` + btrfs/crypto/dm options, `make ARCH=um -jN`.
3. Rootfs: `apt-get download` (no root) + `dpkg-deb -x` of busybox-static,
   btrfs-progs, dmsetup and their shared-lib closure into a dir.
4. Package as **initramfs** (busybox `cpio`), boot UML with plain-file `ubd`
   devices. No debootstrap, no loop mounts, no root at any step.

Artifacts live in `~/uml-smoke/` (build2.sh, rootfs/, initramfs.cpio.gz,
linux-6.12/linux, test*.img).

## Runtime speed (measured)

| Step | Time | Notes |
|---|---|---|
| Kernel source download | ~30 s | 201 MB from GitHub codeload |
| Extract | ~10 s | |
| Configure (defconfig+opts) | ~3 s | |
| Clean kernel build (-j32) | **32 s** | UML is tiny: ~1082 objects |
| Incremental rebuild after config change | ~16 s | |
| Boot + single-dev smoke (mkfs/mount/subvol/snapshot/check) | **~4 s wallclock** | |
| Boot + 20-probe feature sweep (4 devices) | **~11 s wallclock** | |

Full cold-start (download → build → rootfs → first green smoke) was ~2 minutes
here, essentially all of it the one-time 201 MB source download + 32 s build.

Key point: **the README's "~15 min first run" is dominated by debootstrap +
building xfstests, NOT the kernel.** The UML kernel itself builds in the tens of
seconds on this box. Boot-to-btrfs is seconds. Iteration is extremely fast.

## Feature coverage in UML (measured, kernel 6.12 defconfig+btrfs)

PASS (works in UML):
- mkfs.btrfs, mount, unmount, `btrfs check`
- subvolume create, snapshot
- quota enable, qgroup show
- scrub, balance (full)
- fallocate
- compression: zlib, lzo, zstd (all mount + write OK)
- **multi-device: RAID1 and RAID10 mkfs+mount** (verified `filesystem df` shows RAID1/10)
- **device add, device remove** (online)
- loop devices present (`/dev/loop0` available)
- **device-mapper: dm control node present; dmsetup targets registered:**
  `flakey v1.5.0`, `log-writes v1.1.0`, `thin/thin-pool`, `snapshot*`.
  mkfs.btrfs + mount on a `/dev/mapper/flakey` device: **PASS** (with
  `dmsetup mknodes` since there's no udev in the minimal initramfs).

Gaps / not covered:
- Crash-consistency semantics still need care: dm-flakey *loads*, but meaningful
  power-fail tests also want persistent (not tmpfs) backing and the fstests
  dm-log-writes harness plumbing.
- No udev in the minimal initramfs → dm device nodes need manual `dmsetup mknodes`
  (a real debootstrap rootfs has udev and avoids this).
- `btrfs replace` probe FAILED — but that was a test-sequencing bug (target device
  had been `device remove`d first), not a UML limitation. Needs a clean retest.
- SMP concurrency races (the whole point of the TLA+ repo) are still out of reach:
  UML has no real SMP, and KASAN is limited / KCSAN absent. See ASSESSMENT.md.
- Real HW-ish behavior: no discard/TRIM semantics, no write barriers with real
  timing, no realtime device.

## The two false limitations in the repo README

The repo excludes tests that need:
- `SCRATCH_DEV_POOL` (multi-device RAID) — **works fine in UML** via multiple
  `ubd` devices. This is a large chunk of `btrfs/` tests unnecessarily skipped.
- `dm-flakey` / `dm-log-writes` (crash/power-fail) — **the kernel targets work in
  UML**; just enable `CONFIG_BLK_DEV_DM`, `CONFIG_DM_FLAKEY`, `CONFIG_DM_LOG_WRITES`
  (all build for ARCH=um) and provide `dmsetup`.

Only `_require_realtime` looks genuinely UML-incompatible.

## How to (a) speed up

1. **Cache the built kernel + rootfs image as artifacts.** The kernel rarely
   changes; rebuild only on kernel bump. Boot reuses a prebuilt image → seconds.
2. **Skip debootstrap entirely.** Use the `apt-get download` + `dpkg-deb -x` +
   initramfs approach here (rootless, ~seconds to assemble) instead of a multi-
   minute debootstrap. Or cache the debootstrap rootfs once and reuse.
3. **tmpfs-back the ubd images** for smoke runs (`/dev/shm`) — already noted in
   repo; fine for functional smoke (NOT for power-fail fidelity).
4. **Parallel shards** across the 32 cores — the repo's `run-uml-parallel.sh`
   idea is right; with seconds-long boots you can run many short UML instances.
5. **Trim the config** for smoke (drop debug integrity checks that slow I/O) and
   keep a separate heavier "debug" config for deeper runs.

## How to (b) cover more features in UML

1. **Enable device-mapper** (done above) → unlock the dm-flakey /
   dm-log-writes crash-consistency and dm-error test groups.
2. **Add multi-device test coverage** with 4–8 `ubd` devices → RAID0/1/10/DUP,
   device add/remove/replace, balance conversions, degraded mounts.
3. **Turn on the debug detectors that DO work in UML**: `CONFIG_BTRFS_DEBUG`,
   `BTRFS_ASSERT`, `BTRFS_FS_REF_VERIFY` (already on), plus lockdep
   (`PROVE_LOCKING`), `DEBUG_LIST`, `KASAN` (UML KASAN is limited but partially
   works) to make smoke runs actually catch corruption/UAF, not just pass/fail.
4. **Use a real (debootstrap or cached) rootfs with udev + coreutils** so dm nodes
   and `cp --reflink` work without manual plumbing, and run actual xfstests
   `./check` groups instead of hand probes.
5. **Wire the bpftrace tracing kit** from btrfs-tla-verification as a live oracle —
   BUT note UML does not expose kprobes/eBPF, so that must run under qemu/KVM, not
   UML (see ASSESSMENT.md). For UML smoke, rely on in-kernel asserts + `btrfs check`.

## Recommended next steps

- Fix `setup-uml-env.sh`: parameterize `BASE` (not hardcoded `/home/ubuntu`),
  fix the `linux-6.19.9` dir-name-vs-"latest stable" mismatch, and switch the
  source URL to a working mirror (GitHub codeload / cached tarball).
- Add a rootless fast-path (this initramfs approach) as the default smoke target;
  keep the debootstrap path for full xfstests runs.
- Add DM + multi-device kernel options to the config fragment.
- Clone xfstests once (cached) and actually run `-g quick` btrfs+generic groups to
  get a real pass/fail baseline and a true test count (the README's ~580 is an
  estimate; re-derive it now that multi-dev + dm are in scope).
