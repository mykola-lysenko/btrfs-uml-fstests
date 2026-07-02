# Rootless UML xfstests recipe (working)

Environment: WSL2, no passwordless sudo, cdn.kernel.org blocked.

## Key facts discovered
- UML kernel: build ARCH=um, ~32s clean on 32 cores. Single CPU (NPROC=1) in guest.
- mem=NNNNM works (guest MemTotal tracks it) despite a cosmetic "Unknown kernel
  command line parameters" warning.
- Rootfs: assembled rootless via `apt-get download` + `dpkg-deb -x` of ~280 pkgs
  (full closure incl pre-depends) into rootfs-xfs/, merged-/usr symlinks
  (bin/sbin/lib/lib64 -> usr/*). Must create alias symlinks dpkg's
  update-alternatives normally makes: awk->gawk, sh->dash, aclocal->aclocal-1.16,
  automake->automake-1.16, logger->busybox.
- Boot root via hostfs: rootfstype=hostfs rootflags=<abs path to rootfs-xfs> rw.
- Building xfstests IN UML is very slow (single slow CPU, ~30min). Instead build on
  HOST via unprivileged user namespace bind-mounting the prefix over /usr:
    unshare --map-root-user --mount bash -c 'mount --bind rootfs-xfs/usr /usr; \
      export PATH=/usr/bin:/usr/sbin:/bin:/sbin; cd /tmp/xfsbuild; make -j32'
  -> full build in ~12s. Needs libltdl-dev, xfslibs-dev extracted into prefix.
  Persist built tree to xfstests-built/; guest restores it to tmpfs (host-built
  x86-64 binaries run fine in the guest, same userspace).

## Gotchas (each cost a debug cycle)
- util-linux `mount` fails under UML with "must be superuser" even as uid=euid=0
  (mount(2) returns EPERM for it; busybox mount(2) works). Workaround: set
  MOUNT_PROG/UMOUNT_PROG to busybox wrappers in local.config.
- UML sets phantom root=98:0 = /dev/ubda, so xfstests sees /dev/ubda "mounted on /".
  => Do NOT use ubda as TEST/SCRATCH. Use ubdb/ubdc; pass a dummy ubda so the ubd
  subsystem initializes and /dev/ubdb,/dev/ubdc appear as block devices.
- UML flock()s ubd backing files: two UML instances on the same image -> second
  gets errno=11 (EAGAIN) "Can't open". RUN ONE UML AT A TIME. (Overlapping
  background boots silently corrupt runs.)
- xfstests needs RECREATE_TEST_DEV=true (TEST_DEV starts raw).
- Missing utils that abort check: bc, logger, hostname, awk, ps/killall. Add them.

## Boot command (single instance!)
  timeout 900 ./linux-6.12/linux \
    rootfstype=hostfs rootflags=$PWD/rootfs-xfs rw init=/init \
    ubda=$PWD/ubda_dummy.img ubdb=$PWD/test.img ubdc=$PWD/test2.img \
    mem=8000M con0=fd:0,fd:1 con=null

## Observed timing (UML, single CPU)
- boot + restore prebuilt tree + config: ~12-17s
- btrfs/001: 17s.  btrfs/002 (fsstress-heavy): minutes (matches README's slow-test note).

## FIRST GREEN RESULT (2026-07-02)
./check on btrfs (kernel 6.12, UML single-CPU, tmpfs test devs):
  Ran: btrfs/001 btrfs/006 btrfs/007 generic/001 generic/002 generic/005 generic/011
  Not run: btrfs/006  (needs SCRATCH_DEV_POOL - multi-device; enable via extra ubd + SCRATCH_DEV_POOL=)
  Passed all 7 tests
Per-test wall time in UML: btrfs/001 16s, btrfs/007 18s, generic/001 91s,
  generic/002 21s, generic/005 15s, generic/011 21s.
=> Per-test overhead is high (UML single slow CPU). generic/001 (many small ops) = 91s.
   fsstress-heavy tests (btrfs/002) are pathologically slow (>10min) - exclude from smoke.
(The mv check.time ownership warning at end is harmless - hostfs owned by host uid.)

## Speed implication for a full -g quick run
~900 quick tests x avg tens of seconds each, single-CPU, serial => many hours in ONE UML.
The win is PARALLELISM: run N UML shards (host has 32 cores), each its own rootfs
copy + ubd images (remember: one UML per image set - flock). ~16 shards feasible.
Also: exclude the handful of fsstress soak tests from "smoke"; run those separately.
