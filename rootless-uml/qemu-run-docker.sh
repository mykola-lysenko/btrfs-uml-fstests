#!/bin/bash
# Reproduce btrfs/301 in real x86 QEMU/KVM via the btrfs-trace container (no host install).
KIMG="${1:-x86-v71rc7/arch/x86/boot/bzImage}"; OUT="${2:-qemu-301.log}"
docker run --rm --device /dev/kvm -v /home/prozak/uml-smoke:/uml -w /uml btrfs-trace:latest \
  qemu-system-x86_64 -enable-kvm -cpu host -m 4G -smp 4 \
    -kernel "/uml/$KIMG" \
    -append "root=/dev/vda rw console=ttyS0 init=/qemu-init panic=-1" \
    -drive file=/uml/qemu-rootfs.img,if=virtio,format=raw \
    -drive file=/uml/qemu-vdb.img,if=virtio,format=raw \
    -drive file=/uml/qemu-vdc.img,if=virtio,format=raw \
    -nographic -no-reboot > "/home/prozak/uml-smoke/$OUT" 2>&1
