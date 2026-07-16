#!/bin/bash
# t6-probe.sh — reproduce generic/044 under load and PRESERVE the corrupt
# scratch image for forensics (one test per boot; the image is the evidence).
set -u
B=/home/prozak/uml-smoke
KERNEL="${KERNEL:-$B/linux-mainline/linux}"
ITER="${ITER:-10}"; LOAD="${LOAD:-10}"; TEST="${TEST:-generic/044}"
OUT=$B/results/t6-${TAG:-x}; mkdir -p $OUT
log(){ echo "[$(date '+%H:%M:%S')] $*" | tee -a $OUT/log; }

mkshard(){ local d=$B/shards/$1; rm -rf $d; mkdir -p $d/results
  [ -n "${EXTRA:-}" ] && printf '%s\n' "$EXTRA" > $d/extra.config
  shift; printf '%s\n' "$@" | tr ' ' '\n' > $d/RUN_ARGS
  truncate -s 64M $d/dummy.img
  truncate -s 3G $d/test.img $d/scratch.img $d/pool1.img $d/pool2.img $d/pool3.img $d/pool4.img $d/logw.img; }
boot(){ local d=$B/shards/$1
  "$KERNEL" rootfstype=hostfs rootflags=$B/rootfs-xfs rw init=/shard-init.sh \
    shard="$1" umid="$1" \
    ubda=$d/dummy.img ubdb=$d/test.img ubdc=$d/scratch.img \
    ubdd=$d/pool1.img ubde=$d/pool2.img ubdf=$d/pool3.img ubdg=$d/pool4.img \
    ubdh=$d/logw.img \
    seccomp=on mem="$2" con0=fd:0,fd:1 con=null < /dev/null > $d/boot.out 2>&1; }

mapfile -t FAST < <(sort -t' ' -k2 -n $B/results/times-db.txt | awk '$2<=15{print $1}' | head -300)
for ((l=0;l<LOAD;l++)); do
  slice=(); for ((i=l;i<${#FAST[@]};i+=LOAD)); do slice+=("${FAST[$i]}"); done
  mkshard "t6ld$l" "${slice[@]}"; boot "t6ld$l" 1000M &
done
log "load fleet: $LOAD guests"

hits=0
for ((it=1;it<=ITER;it++)); do
  mkshard t6p "$TEST"
  boot t6p 2000M
  if grep -qE 'output mismatch|\[failed' $B/shards/t6p/results/run.log 2>/dev/null; then
    hits=$((hits+1))
    cp $B/shards/t6p/scratch.img $OUT/corrupt-$it.img
    cp -a $B/shards/t6p/results $OUT/results-$it
    log "iter $it: FAIL -> image saved ($OUT/corrupt-$it.img)"
  else
    log "iter $it: pass"
  fi
done
pkill -9 -f 'umid=t6ld' 2>/dev/null
log "done: $hits/$ITER failures"
