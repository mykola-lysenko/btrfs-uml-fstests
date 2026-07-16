#!/bin/bash
# flake-probe.sh — reproduce the load-dependent failures of generic/044-046,747.
# Runs the suspect tests ITER times in a fresh UML each iteration, while a
# fleet of load UMLs runs fast tests to recreate the full-suite conditions.
# Usage: KERNEL=<path> TAG=<name> [ITER=5] [LOAD=6] ./flake-probe.sh
set -u
BASE=$HOME/uml-smoke
KERNEL="${KERNEL:?}"; TAG="${TAG:?}"
ITER="${ITER:-5}"; LOAD="${LOAD:-6}"
SUSPECTS="generic/044 generic/045 generic/046 generic/747"
OUT=$BASE/results/flake-$TAG
mkdir -p $OUT
log(){ echo "[$(date '+%H:%M:%S')] $*" | tee -a $OUT/log; }

boot(){ # $1 shard-name  $2 mem  -> boots UML, waits for poweroff
  local d=$BASE/shards/$1
  "$KERNEL" rootfstype=hostfs rootflags=$BASE/rootfs-xfs rw init=/shard-init.sh \
    shard="$1" umid="$1" \
    ubda=$d/dummy.img ubdb=$d/test.img ubdc=$d/scratch.img \
    ubdd=$d/pool1.img ubde=$d/pool2.img ubdf=$d/pool3.img ubdg=$d/pool4.img \
    ubdh=$d/logw.img \
    seccomp=on mem="$2" con0=fd:0,fd:1 con=null > $d/boot.out 2>&1
}
mkshard(){ # $1 name $2 tests...
  local d=$BASE/shards/$1; rm -rf $d; mkdir -p $d/results
  shift; printf '%s\n' "$@" | tr ' ' '\n' > $d/RUN_ARGS
  truncate -s 64M $d/dummy.img
  truncate -s 3G $d/test.img $d/scratch.img $d/pool1.img $d/pool2.img $d/pool3.img $d/pool4.img $d/logw.img
}

# Load fleet: slices of the fast quick tests, booted once, run in background.
mapfile -t FAST < <(sort -t' ' -k2 -n $BASE/results/times-db.txt | awk '$2<=15{print $1}' | head -240)
for ((l=0;l<LOAD;l++)); do
  slice=(); for ((i=l;i<${#FAST[@]};i+=LOAD)); do slice+=("${FAST[$i]}"); done
  mkshard "ld$l" "${slice[@]}"
  boot "ld$l" 1200M &
done
log "load fleet: $LOAD UMLs x ~$(( ${#FAST[@]} / LOAD )) fast tests"

# Probe iterations under load.
for ((it=1;it<=ITER;it++)); do
  mkshard "fp" $SUSPECTS
  boot "fp" 2000M
  res=$(grep -E 'Passed all|Failures:' $BASE/shards/fp/results/run.log 2>/dev/null | tail -1)
  fails=$(grep -rh 'output mismatch|\[failed' $BASE/shards/fp/results/run.log 2>/dev/null | grep -oE '^[begx][a-z0-9]*/[0-9]+' | sort -u | tr '\n' ' ')
  log "iter $it: ${res:-no-result} ${fails:+FAILED: $fails}"
  cp -a $BASE/shards/fp/results $OUT/iter$it 2>/dev/null
done
# stop load fleet
pkill -9 -f 'umid=ld' 2>/dev/null
log "probe done -> $OUT"
