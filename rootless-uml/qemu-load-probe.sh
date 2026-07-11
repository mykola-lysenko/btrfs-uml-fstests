#!/bin/bash
# QEMU-under-load discriminator for the generic/044-046,747 load flake.
set -u
BASE=$HOME/uml-smoke
LOAD=6
OUT=$BASE/results/flake-qemu
mkdir -p $OUT
log(){ echo "[$(date '+%H:%M:%S')] $*" | tee -a $OUT/log; }
# load fleet (same as flake-probe): UMLs chewing fast tests on the host
mapfile -t FAST < <(sort -t' ' -k2 -n $BASE/results/times-db.txt | awk '$2<=20{print $1}' | head -480)
for ((l=0;l<LOAD;l++)); do
  d=$BASE/shards/qld$l; rm -rf $d; mkdir -p $d/results
  for ((i=l;i<${#FAST[@]};i+=LOAD)); do echo "${FAST[$i]}"; done > $d/RUN_ARGS
  truncate -s 64M $d/dummy.img
  truncate -s 3G $d/test.img $d/scratch.img $d/pool1.img $d/pool2.img $d/pool3.img $d/pool4.img $d/logw.img
  $BASE/linux-for-next-0710/linux rootfstype=hostfs rootflags=$BASE/rootfs-xfs rw \
    init=/shard-init.sh shard=qld$l umid=qld$l \
    ubda=$d/dummy.img ubdb=$d/test.img ubdc=$d/scratch.img \
    ubdd=$d/pool1.img ubde=$d/pool2.img ubdf=$d/pool3.img ubdg=$d/pool4.img ubdh=$d/logw.img \
    seccomp=on mem=1200M con0=null con=null > $d/boot.out 2>&1 &
done
log "load fleet: $LOAD UMLs x ~80 fast tests"
# QEMU probe: mainline x86 kernel (flake shows on both kernels; mainline = cleaner baseline)
truncate -s 8G qemu-vdb.img qemu-vdc.img
$BASE/run-qemu.sh -enable-kvm -cpu host -m 4G -smp 4 \
    -kernel $BASE/x86-mainline/arch/x86/boot/bzImage \
    -append "root=/dev/vda rw console=ttyS0 init=/qemu-init qtests=generic/044,generic/045,generic/046,generic/747 qloop=6 panic=-1" \
    -drive file=$BASE/qemu-rootfs.img,if=virtio,format=raw \
    -drive file=$BASE/qemu-vdb.img,if=virtio,format=raw \
    -drive file=$BASE/qemu-vdc.img,if=virtio,format=raw \
    -nic none -nographic -no-reboot > $OUT/qemu.out 2>&1
grep -E 'QITER|RUN DONE' $OUT/qemu.out | tee -a $OUT/log
pkill -9 -f 'umid=qld' 2>/dev/null
log "qemu-load probe done"
