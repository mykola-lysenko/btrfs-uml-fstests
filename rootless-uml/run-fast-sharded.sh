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

# One UML per image set: fresh images + per-shard RUN_ARGS.
rm -rf "$BASE/shards"
for ((n=0; n<SHARDS; n++)); do
  d="$BASE/shards/$n"; mkdir -p "$d/results"
  : > "$d/RUN_ARGS"
  truncate -s 64M "$d/dummy.img"; truncate -s "$IMG_SIZE" "$d/test.img" "$d/scratch.img"
done

# Distribution. With a TIMES file (lines "test seconds", e.g. results/measured-times.txt)
# use greedy longest-processing-time bin-packing so shards finish evenly — round-robin
# leaves one shard the long pole when a few tests dominate (measured ~4x vs ~10x). Without
# TIMES, fall back to round-robin.
TIMES="${TIMES:-}"
if [ -n "$TIMES" ] && [ -f "$TIMES" ]; then
  log "load-balancing by measured time ($TIMES, greedy LPT)"
  # emit "seconds test" for each test (unknown times default to the median-ish 12s), sort desc,
  # then assign each to the least-loaded shard.
  paste <(printf '%s\n' "${TESTS[@]}") \
        <(for t in "${TESTS[@]}"; do awk -v k="$t" '$1==k{print $2; f=1} END{if(!f)print 12}' "$TIMES"; done) \
    | sort -k2 -rn | while read -r t secs; do
        n=$(for ((s=0;s<SHARDS;s++)); do printf '%s %s\n' "$s" "$(awk '{x+=$2}END{print x+0}' "$BASE/shards/$s/RUN_ARGS.load" 2>/dev/null)"; done | sort -k2 -n | head -1 | cut -d' ' -f1)
        echo "$t" >> "$BASE/shards/$n/RUN_ARGS"
        echo "x $secs" >> "$BASE/shards/$n/RUN_ARGS.load"
      done
  rm -f "$BASE"/shards/*/RUN_ARGS.load
else
  for i in "${!TESTS[@]}"; do echo "${TESTS[$i]}" >> "$BASE/shards/$((i % SHARDS))/RUN_ARGS"; done
fi

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
