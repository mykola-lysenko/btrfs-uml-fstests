#!/bin/bash
# Supervised sharded xfstests runner with stall detection + recovery.
#
# Each shard is one UML running ./check over its slice, serially. A test that
# wedges in uninterruptible (D) kernel state can't be killed by the per-test
# timeout, so it stalls the whole shard. This supervisor watches each shard; if
# it sits on one test longer than STALL seconds (i.e. past the per-test timeout,
# so it's a true hang), it kills the shard, blacklists that test, and relaunches
# the shard with only its REMAINING tests. Results accumulate across restarts.
set -uo pipefail
BASE="${BASE:-$HOME/uml-smoke}"
SHARDS="${SHARDS:-16}"
KERNEL="${KERNEL:-$BASE/linux-btrfs-for-next/linux.nofp}"
LIST="${LIST:-$BASE/results/quick-all.txt}"
BLACKLIST_FILE="${BLACKLIST:-$BASE/results/blacklist.txt}"
MEM="${MEM:-1500M}"; IMG_SIZE="${IMG_SIZE:-3G}"; INIT="/shard-init.sh"
ROOTFS="$BASE/rootfs-xfs"
STALL="${STALL:-200}"; POLL="${POLL:-15}"; MAX_RESTARTS="${MAX_RESTARTS:-8}"
log(){ echo "[$(date '+%H:%M:%S')] $*"; }

declare -A BL
BL[__none__]=1; unset 'BL[__none__]'
touch "$BLACKLIST_FILE"
while read -r t; do [ -n "$t" ] && BL["$t"]=1; done < <(grep -vE '^#|^\s*$' "$BLACKLIST_FILE")
mapfile -t ALL < <(grep -vE '^#|^\s*$' "$LIST")
TESTS=(); for t in "${ALL[@]}"; do [ -n "${BL[$t]:-}" ] || TESTS+=("$t"); done
log "${#TESTS[@]} tests (of ${#ALL[@]}) after blacklist(${#BL[@]}); $SHARDS shards; stall=${STALL}s"

rm -rf "$BASE/shards"
for ((n=0;n<SHARDS;n++)); do mkdir -p "$BASE/shards/$n/results"; : > "$BASE/shards/$n/RUN_ARGS"; done
for i in "${!TESTS[@]}"; do echo "${TESTS[$i]}" >> "$BASE/shards/$((i%SHARDS))/RUN_ARGS"; done

declare -A PID DONE RESTARTS CURTEST CURSINCE
launch(){ local n=$1 d="$BASE/shards/$1"
  truncate -s 64M "$d/dummy.img"; truncate -s "$IMG_SIZE" "$d/test.img" "$d/scratch.img"
  # extra scratch-pool devices (sparse) -> guest enables SCRATCH_DEV_POOL
  truncate -s "$IMG_SIZE" "$d/pool1.img" "$d/pool2.img" "$d/pool3.img" "$d/pool4.img" "$d/logw.img"
  "$KERNEL" rootfstype=hostfs rootflags="$ROOTFS" rw init="$INIT" shard="$n" \
    ubda="$d/dummy.img" ubdb="$d/test.img" ubdc="$d/scratch.img" \
    ubdd="$d/pool1.img" ubde="$d/pool2.img" ubdf="$d/pool3.img" ubdg="$d/pool4.img" \
    ubdh="$d/logw.img" \
    seccomp=on mem="$MEM" con0=fd:0,fd:1 con=null > "$d/boot.out" 2>&1 &
  PID[$n]=$!; CURTEST[$n]=""; CURSINCE[$n]=$(date +%s)
}
# completed/running derived from ALL run.log parts in the shard dir
comp_tests(){ grep -hoE '^[bg][a-z]*/[0-9]+ +([0-9]+s|.*not run)' "$BASE/shards/$1"/results/run.log* 2>/dev/null | grep -oE '^[bg][a-z]*/[0-9]+'; }
curtest(){ local l; l=$(tail -1 "$BASE/shards/$1/results/run.log" 2>/dev/null); echo "$l"|grep -qE '[0-9]+s *$|not run' && echo "" || echo "$l"|grep -oE '^[bg][a-z]*/[0-9]+'; }
# recover a shard (from a stall OR a crash): blacklist the bad test, save this
# attempt's results, and relaunch with the remaining tests.
recover(){ local n=$1 bad=$2 reason=$3
  if [ -n "$bad" ] && [ -z "${BL[$bad]:-}" ]; then
    BL["$bad"]=1; echo "$bad" >> "$BLACKLIST_FILE"; echo "$bad" >> "$BASE/results/$reason.txt"; fi
  kill -9 "${PID[$n]}" 2>/dev/null; pkill -9 -f "$BASE/shards/$n/test.img" 2>/dev/null; sleep 1
  mv "$BASE/shards/$n/results/run.log" "$BASE/shards/$n/results/run.log.r${RESTARTS[$n]}" 2>/dev/null
  # keep the crash-time console for forensics (panic signature: SIGBUS vs oops)
  cp "$BASE/shards/$n/boot.out" "$BASE/shards/$n/boot.out.r${RESTARTS[$n]}" 2>/dev/null
  mapfile -t rem < <(comm -23 <(sort -u "$BASE/shards/$n/RUN_ARGS") \
                              <({ comp_tests $n; for t in "${!BL[@]}"; do echo "$t"; done; } | sort -u))
  if [ "${#rem[@]}" -gt 0 ] && [ "${RESTARTS[$n]}" -lt "$MAX_RESTARTS" ]; then
    printf '%s\n' "${rem[@]}" > "$BASE/shards/$n/RUN_ARGS"
    RESTARTS[$n]=$(( RESTARTS[$n]+1 ))
    log "shard $n restart #${RESTARTS[$n]} with ${#rem[@]} remaining ($reason recovery)"
    launch $n
  else
    DONE[$n]=1; log "shard $n done (${#rem[@]} remaining, restarts=${RESTARTS[$n]})"
  fi
}

t0=$(date +%s)
for ((n=0;n<SHARDS;n++)); do DONE[$n]=0; RESTARTS[$n]=0; [ -s "$BASE/shards/$n/RUN_ARGS" ] && launch $n || DONE[$n]=1; done
log "launched; monitoring..."

while :; do
  active=0
  for ((n=0;n<SHARDS;n++)); do
    [ "${DONE[$n]}" = 1 ] && continue
    if ! kill -0 "${PID[$n]}" 2>/dev/null; then
      if grep -q 'SHARD.*DONE' "$BASE/shards/$n/boot.out" 2>/dev/null; then
        DONE[$n]=1; log "shard $n finished cleanly (completed=$(comp_tests $n|sort -u|wc -l))"
      else
        ct=$(curtest $n)
        log "shard $n CRASHED on ${ct:-?} (completed=$(comp_tests $n|sort -u|wc -l)) -> blacklist + recover"
        recover $n "$ct" crash
      fi
      continue
    fi
    active=1
    ct=$(curtest $n); now=$(date +%s)
    [ "$ct" != "${CURTEST[$n]}" ] && { CURTEST[$n]="$ct"; CURSINCE[$n]=$now; }
    if [ -n "$ct" ] && [ $((now-${CURSINCE[$n]})) -ge $STALL ]; then
      # A delta far beyond STALL means the host slept (wall clock jumped),
      # not that the test hung — reset the timer instead of blacklisting.
      if [ $((now-${CURSINCE[$n]})) -ge $((4*STALL)) ]; then
        log "shard $n clock jump ($((now-${CURSINCE[$n]}))s) — host suspend? resetting timer for $ct"
        CURSINCE[$n]=$now
      else
        log "shard $n STALLED on $ct for $((now-${CURSINCE[$n]}))s -> blacklist + recover"
        recover $n "$ct" hang
      fi
    fi
  done
  [ "$active" = 0 ] && break
  sleep "$POLL"
done
WALL=$(( $(date +%s)-t0 ))

log "=== AGGREGATE (wall ${WALL}s) ==="
tot=0; pass=0; fail=0; nr=0; failed=""
for ((n=0;n<SHARDS;n++)); do
  logs="$BASE/shards/$n"/results/run.log*
  p=$(grep -hcE '^[bg][a-z]*/[0-9]+ +[0-9]+s *$' $logs 2>/dev/null | paste -sd+ | bc 2>/dev/null); p=${p:-0}
  nrn=$(grep -hcE 'not run' $logs 2>/dev/null | paste -sd+ | bc 2>/dev/null); nrn=${nrn:-0}
  fl=$(grep -hoE '^[bg][a-z]*/[0-9]+' <(grep -hE 'output mismatch|\[failed' $logs 2>/dev/null) | sort -u)
  fn=$(echo "$fl"|grep -cE '^[bg]'); pass=$((pass+p)); nr=$((nr+nrn)); fail=$((fail+fn))
  [ -n "$fl" ] && failed="$failed $fl"
done
to=$(grep -rhoE '^[bg][a-z]*/[0-9]+ +\[failed, exit status 124\]' "$BASE"/shards/*/results/run.log* 2>/dev/null | grep -oE '^[bg][a-z]*/[0-9]+' | sort -u | wc -l)
echo "TOTAL: pass=$pass notrun=$nr failed=$fail (incl ~$to timeout) wall=${WALL}s"
echo "BLACKLIST: $(grep -cE '^[bg]' "$BLACKLIST_FILE") = hangs:$(sort -u "$BASE/results/hang.txt" 2>/dev/null|grep -cE '^[bg]') + crashes:$(sort -u "$BASE/results/crash.txt" 2>/dev/null|grep -cE '^[bg]')"
echo "HANGS: $(sort -u "$BASE/results/hang.txt" 2>/dev/null|grep -hE '^[bg]'|tr '\n' ' ')"
echo "CRASHES: $(sort -u "$BASE/results/crash.txt" 2>/dev/null|grep -hE '^[bg]'|tr '\n' ' ')"
[ -n "$failed" ] && echo "FAILURES:$(echo $failed | tr ' ' '\n' | sort -u | tr '\n' ' ')"
