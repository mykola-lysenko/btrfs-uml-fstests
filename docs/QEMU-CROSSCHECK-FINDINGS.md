# QEMU cross-check: btrfs/301 is a UML artifact, not a btrfs bug

## Result

Same kernel *source* (v7.1-rc7), same btrfs-progs (v7.0), same test — only the
execution environment differs:

| environment | btrfs/301 (qgroup exclusive accounting) |
|-------------|------------------------------------------|
| **UML**  | **FAIL** — deterministic qgroup metadata mismatch (−16384), 2/2 |
| **QEMU/KVM (real x86)** | **PASS** — 3/3 |

So the qgroup accounting mismatch we found under UML **does not reproduce on real
x86**. It is a **UML-specific artifact**, not a btrfs kernel bug. The earlier
"one genuine btrfs finding" is retracted.

Why UML differs is unconfirmed, but qgroup accounting is timing/ordering-sensitive
(delayed refs, transaction commits), and UML's execution model + `ubd` block layer
differ enough from a real block device to perturb it. The point stands regardless:
**a UML-only failure is not a real bug until a real VM reproduces it.**

## Methodology lesson (important)

- **UML is good for fast smoke/coverage triage**, but it can **false-positive** on
  subtle, timing- or environment-sensitive tests (qgroup here).
- **Every UML failure must be confirmed in QEMU** (real x86, real block devices)
  before it's treated as a btrfs bug. This cross-check just prevented a bogus
  upstream report.
- Combined pipeline: **UML to triage fast → QEMU to confirm → report only what
  reproduces on real hardware**, and always on **current upstream** (see the
  stale-base lesson in STABLE-CORE-FINDINGS).

## The QEMU path (rootless, reused)

QEMU needs no host install: a Docker image (`btrfs-trace:latest`, built by the
sibling TLA+ effort) ships `qemu-system-x86` + `virtme-ng`, and KVM is passed via
`--device /dev/kvm` (rootless Docker). We boot our own x86 kernel + an ext4 root
image (built rootlessly with `mkfs.ext4 -d`) + virtio scratch disks:

```sh
docker run --rm --device /dev/kvm -v ~/uml-smoke:/uml -w /uml btrfs-trace:latest \
  qemu-system-x86_64 -enable-kvm -cpu host -m 4G -smp 4 \
    -kernel /uml/x86-<ver>/arch/x86/boot/bzImage \
    -append "root=/dev/vda rw console=ttyS0 init=/qemu-init panic=-1" \
    -drive file=/uml/qemu-rootfs.img,if=virtio,format=raw \
    -drive file=/uml/qemu-vdb.img,if=virtio,format=raw \
    -drive file=/uml/qemu-vdc.img,if=virtio,format=raw \
    -nographic -no-reboot
```

Build the x86 kernel with `rootless-uml/build-x86.sh <name>` (x86_64_defconfig +
btrfs + virtio, builtin). See `rootless-uml/qemu-run-docker.sh`.

## Side note: the mount failure was never UML-specific

util-linux `mount` fails with "must be superuser" even as real root **in QEMU too**
— so it's a property of our minimal deb-extracted rootfs, not UML. We work around it
with the `bbmount` (busybox) wrapper in both. Worth a future fix for test fidelity.
