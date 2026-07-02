# Rootless UML btrfs testing

A fully **rootless** pipeline (no sudo, no debootstrap, no loop mounts) for running
btrfs smoke tests and xfstests inside User Mode Linux. Built to work in constrained
environments (WSL2, CI containers) where `sudo` needs a password and
`cdn.kernel.org` is unreachable.

See [`../docs/HOWTO-xfstests-rootless.md`](../docs/HOWTO-xfstests-rootless.md) for
the full walkthrough and every gotcha, and
[`../docs/SMOKE-TEST-FINDINGS.md`](../docs/SMOKE-TEST-FINDINGS.md) for measured
speed and feature-coverage results.

## Pipeline

```
build-uml-kernel.sh        # ARCH=um kernel + btrfs + device-mapper (~30s on many cores)
fetch-rootfs-pkgs.sh       # apt-get download the full dep closure (rootless)
assemble-rootfs.sh         # extract debs -> rootfs tree; fix merged-/usr, aliases, mount wrappers
build-xfstests-hostside.sh # build xfstests on host via userns bind-mount (~12s)
```

Then boot one UML instance:

- **Smoke + feature probe** (seconds): boot `smoke-init.sh` as init with 4 ubd
  devices. Proves mkfs/mount/subvol/snapshot plus RAID1/10, compression, and
  dm-flakey all work in UML.
- **xfstests**: put a test list in `$BASE/RUN_ARGS`, boot `xfstests-init.sh` as
  init (hostfs root). Results land in `$BASE/results/`.

## Key constraints (learned the hard way — details in the HOWTO)

- **One UML per image set.** UML `flock()`s ubd backing files; overlapping
  instances get `errno=11` and silently corrupt each other.
- **Don't use `/dev/ubda` for test/scratch.** UML's phantom `root=98:0` aliases
  ubda; pass a dummy ubda and use ubdb/ubdc.
- **util-linux `mount` EPERMs under UML** even as uid 0 — busybox mount works, so
  we point `MOUNT_PROG`/`UMOUNT_PROG` at `bin/bbmount`.
- **Per-test time is high** (single slow UML CPU): 15–90s per test, and fsstress
  soak tests (btrfs/002) are >10 min. Parallelize across host cores; exclude soak
  tests from "smoke".
