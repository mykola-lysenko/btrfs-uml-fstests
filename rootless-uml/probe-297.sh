#!/bin/bash
# probe-297.sh <kernel> <label> <iters> — btrfs/297 solo, N fresh boots
B=/home/prozak/uml-smoke; K=$1; L=$2; N=${3:-5}
d=$B/shards/p297; pass=0; fail=0
for i in $(seq $N); do
  rm -rf $d; mkdir -p $d/results; echo btrfs/297 > $d/RUN_ARGS
  truncate -s 64M $d/dummy.img
  truncate -s 8G $d/test.img $d/scratch.img $d/pool1.img $d/pool2.img $d/pool3.img $d/pool4.img $d/logw.img
  $K rootfstype=hostfs rootflags=$B/rootfs-xfs rw init=/shard-init.sh shard=p297 \
    ubda=$d/dummy.img ubdb=$d/test.img ubdc=$d/scratch.img \
    ubdd=$d/pool1.img ubde=$d/pool2.img ubdf=$d/pool3.img ubdg=$d/pool4.img ubdh=$d/logw.img \
    seccomp=on mem=3000M con0=fd:0,fd:1 con=null < /dev/null > $d/boot.out 2>&1
  if grep -qE '^btrfs/297 +[0-9]+s *$' $d/results/run.log 2>/dev/null; then
    pass=$((pass+1)); v=PASS
  else fail=$((fail+1)); v=FAIL
    cp $d/results/btrfs/297.out.bad $B/results/297-$L-iter$i.out.bad 2>/dev/null
    grep -A2 'first 16 bytes' $d/results/btrfs/297.full 2>/dev/null | head -3 > $B/results/297-$L-iter$i.parity
  fi
  echo "$L iter$i: $v"
done
echo "$L TOTAL: $pass pass / $fail fail of $N"
