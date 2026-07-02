#!/bin/bash
# run-fast-sharded.sh — run an xfstests test list across N parallel UML shards.
#
# Distributes the list round-robin over N shards, launches N single-core UML
# instances concurrently (each with seccomp=on and its own ubd images), waits for
# all, and aggregates pass/fail/notrun plus wall-clock. Near-linear speedup on a
# many-core host; composes with seccomp's ~1.7x.
#
# Usage:
#   BASE=~/uml-smoke SHARDS=16 KERNEL=~/uml-smoke/linux-btrfs-for-next/linux \
#   LIST=~/uml-smoke/results/quick-fast.txt ./run-fast-sharded.sh
set -uo pipefail
BASE="${BASE:-$HOME/uml-smoke}"
SHARDS="${SHARDS:-16}"
KERNEL="${KERNEL:-$BASE/linux-btrfs-for-next/linux}"
LIST="${LIST:-$BASE/results/quick-fast.txt}"
MEM="${MEM:-1500M}"
IMG_SIZE="${IMG_SIZE:-3G}"
INIT="${INIT:-/shard-init.sh}"
ROOTFS="$BASE/rootfs-xfs"
log(){ echo "[$(date '+%H:%M:%S')] $*"; }

# Test IDs from LIST (skip comments/blanks).
mapfile -t TESTS < <(grep -vE '^\s*#|^\s*$' "$LIST")
[ "${#TESTS[@]}" -gt 0 ] || { echo "no tests in $LIST"; exit 1; }
log "distributing ${#TESTS[@]} tests over $SHARDS shards; kernel=$(basename "$(dirname "$KERNEL")")"

# One UML per image set: fresh images + round-robin RUN_ARGS per shard.
rm -rf "$BASE/shards"
for ((n=0; n<SHARDS; n++)); do
  d="$BASE/shards/$n"; mkdir -p "$d/results"
  : > "$d/RUN_ARGS"
  truncate -s 64M "$d/dummy.img"; truncate -s "$IMG_SIZE" "$d/test.img" "$d/scratch.img"
done
for i in "${!TESTS[@]}"; do echo "${TESTS[$i]}" >> "$BASE/shards/$((i % SHARDS))/RUN_ARGS"; done

log "launching $SHARDS UML shards (seccomp=on, mem=$MEM)..."
t0=$(date +%s)
pids=()
SHARD_TIMEOUT="${SHARD_TIMEOUT:-3600}"   # cap per shard so a hung test can't block forever
for ((n=0; n<SHARDS; n++)); do
  d="$BASE/shards/$n"
  timeout "$SHARD_TIMEOUT" "$KERNEL" \
    rootfstype=hostfs rootflags="$ROOTFS" rw init="$INIT" shard="$n" \
    ubda="$d/dummy.img" ubdb="$d/test.img" ubdc="$d/scratch.img" \
    seccomp=on mem="$MEM" con0=fd:0,fd:1 con=null \
    > "$d/boot.out" 2>&1 &
  pids+=($!)
done
log "waiting for ${#pids[@]} shards..."
for p in "${pids[@]}"; do wait "$p"; done
WALL=$(( $(date +%s)-t0 ))

# Aggregate.
log "=== AGGREGATE (wall clock ${WALL}s) ==="
tot_ran=0 tot_notrun=0 tot_fail=0; failed_list=""
for ((n=0; n<SHARDS; n++)); do
  rl="$BASE/shards/$n/results/run.log"
  [ -f "$rl" ] || { echo "shard $n: no run.log"; continue; }
  ran=$(grep -oE 'Ran: .*' "$rl" | tr ' ' '\n' | grep -cE '^[bg].*/[0-9]+')
  notrun=$(grep -oE 'Not run: .*' "$rl" | tr ' ' '\n' | grep -cE '^[bg].*/[0-9]+')
  fails=$(grep -oE 'Failures: .*' "$rl" | sed 's/Failures: //')
  nfail=$(echo "$fails" | tr ' ' '\n' | grep -cE '^[bg].*/[0-9]+')
  tot_ran=$((tot_ran+ran)); tot_notrun=$((tot_notrun+notrun)); tot_fail=$((tot_fail+nfail))
  [ -n "$fails" ] && failed_list="$failed_list $fails"
  printf "  shard %2d: ran=%-4s notrun=%-4s fail=%-3s\n" "$n" "$ran" "$notrun" "$nfail"
done
echo "-----------------------------------------------"
echo "TOTAL: ran=$tot_ran notrun=$tot_notrun failed=$tot_fail  wall=${WALL}s"
[ "$tot_fail" -gt 0 ] && echo "FAILURES:$failed_list"
echo "per-shard logs: $BASE/shards/<n>/results/run.log"
