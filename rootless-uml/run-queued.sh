#!/bin/bash
# run-queued.sh — queue-fed sharded xfstests runner (v3 scheduler).
#
# Tests live as claim-files in a shared hostfs queue; guests pop them by
# atomic rename (see queue-init.sh). vs the LPT supervisor:
#  - no straggler tail (no projection error: work self-balances),
#  - ordering control: top-K global longest first (they bound the makespan),
#    then btrfs longest->shortest (time-to-btrfs-signal), then generic,
#  - crash on a slim lane requeues the culprit test to the fat queue once
#    (memory-shaped failures self-heal) before blacklisting.
# Keeps: tiered memory/images/stall, archiving, RSS+times harvesting,
# suspend-jump guard, solo-retry failure classifier.
set -uo pipefail
BASE="${BASE:-$HOME/uml-smoke}"
SHARDS="${SHARDS:-8}"                 # slim lanes
BIG_SHARDS="${BIG_SHARDS:-3}"         # fat lanes
TOT=$((SHARDS+BIG_SHARDS))
KERNEL="${KERNEL:-$BASE/linux-mainline/linux}"
LIST="${LIST:-$BASE/results/quick-all.txt}"
BLACKLIST_FILE="${BLACKLIST:-$BASE/results/blacklist.txt}"
MEM="${MEM:-1500M}"; MEM_BIG="${MEM_BIG:-3000M}"
IMG_SIZE="${IMG_SIZE:-3G}"; IMG_SIZE_BIG="${IMG_SIZE_BIG:-8G}"; INIT="/queue-init.sh"
TIMES_DB="${TIMES_DB:-$BASE/results/times-db.txt}"
BIGMEM_FILE="${BIGMEM:-$BASE/results/bigmem.txt}"
ROOTFS="$BASE/rootfs-xfs"
STALL="${STALL:-1000}"; STALL_BIG="${STALL_BIG:-1800}"; POLL="${POLL:-15}"; MAX_RESTARTS="${MAX_RESTARTS:-8}"
QR="$BASE/queue"
log(){ echo "[$(date '+%H:%M:%S')] $*"; }

declare -A BL
BL[__none__]=1; unset 'BL[__none__]'
touch "$BLACKLIST_FILE" "$TIMES_DB" "$BIGMEM_FILE"
while read -r t; do [ -n "$t" ] && BL["$t"]=1; done < <(grep -vE '^#|^\s*$' "$BLACKLIST_FILE")
mapfile -t ALL < <(grep -vE '^#|^\s*$' "$LIST")
TESTS=(); for t in "${ALL[@]}"; do [ -n "${BL[$t]:-}" ] || TESTS+=("$t"); done
log "${#TESTS[@]} tests (of ${#ALL[@]}) after blacklist(${#BL[@]}); $SHARDS slim + $BIG_SHARDS fat lanes (queue mode)"

# Archive previous run's results.
if [ -d "$BASE/shards" ]; then
  ARC="$BASE/results/archive-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$ARC"
  for d in "$BASE"/shards/*/; do
    n=$(basename "$d")
    [ -d "$d/results" ] && mkdir -p "$ARC/$n" && mv "$d/results" "$ARC/$n/" 2>/dev/null
    for b in "$d"/boot.out*; do [ -f "$b" ] && mv "$b" "$ARC/$n/" 2>/dev/null; done
  done
  rm -rf "$BASE/shards"
  log "previous run archived to $ARC"
fi
for ((n=0;n<TOT;n++)); do mkdir -p "$BASE/shards/$n/results"; done

# Build the queue. Filename prefix = execution order.
rm -rf "$QR"; mkdir -p "$QR/q" "$QR/qbig" "$QR/claimed" "$QR/done"
printf '%s\n' "${TESTS[@]}" > "$BASE/shards/.alltests"
python3 - "$TIMES_DB" "$BIGMEM_FILE" "$BASE/shards/.alltests" "$QR" <<'PY'
import sys
db_f, bm_f, list_f, qr = sys.argv[1:5]
times = {}
for line in open(db_f):
    p = line.split()
    if len(p) == 2 and p[1].isdigit(): times[p[0]] = int(p[1])
bigmem = set(l.strip() for l in open(bm_f) if l.strip() and not l.startswith('#'))
tests = [l.strip() for l in open(list_f) if l.strip()]
known = sorted(times.values())
med = known[len(known)//2] if known else 15
t_of = lambda t: times.get(t, med)
slim = [t for t in tests if t not in bigmem]
fat  = [t for t in tests if t in bigmem]
# slim order: top-10 global longest first (bound the tail), then btrfs desc,
# then generic desc
top = sorted(slim, key=lambda t: -t_of(t))[:10]
rest = [t for t in slim if t not in top]
b = sorted([t for t in rest if t.startswith('btrfs/')], key=lambda t: -t_of(t))
g = sorted([t for t in rest if not t.startswith('btrfs/')], key=lambda t: -t_of(t))
order = top + b + g
for i, t in enumerate(order):
    open(f"{qr}/q/{i:04d}_{t.replace('/','_')}", "w").write(t + "\n")
for i, t in enumerate(sorted(fat, key=lambda t: -t_of(t))):
    open(f"{qr}/qbig/{i:04d}_{t.replace('/','_')}", "w").write(t + "\n")
print(f"queue built: slim={len(order)} fat={len(fat)} "
      f"(est work slim={sum(map(t_of,order))}s fat={sum(map(t_of,fat))}s)")
PY

declare -A PID DONE RESTARTS CURTEST CURSINCE
shard_mem(){ [ "$1" -ge "$SHARDS" ] && echo "$MEM_BIG" || echo "$MEM"; }
shard_role(){ [ "$1" -ge "$SHARDS" ] && echo fat || echo slim; }
launch(){ local n=$1 d="$BASE/shards/$1"
  local isz; isz=$([ "$n" -ge "$SHARDS" ] && echo "$IMG_SIZE_BIG" || echo "$IMG_SIZE")
  truncate -s 64M "$d/dummy.img"; truncate -s "$isz" "$d/test.img" "$d/scratch.img"
  truncate -s "$isz" "$d/pool1.img" "$d/pool2.img" "$d/pool3.img" "$d/pool4.img" "$d/logw.img"
  "$KERNEL" rootfstype=hostfs rootflags="$ROOTFS" rw init="$INIT" shard="$n" \
    qrole="$(shard_role $n)" \
    ubda="$d/dummy.img" ubdb="$d/test.img" ubdc="$d/scratch.img" \
    ubdd="$d/pool1.img" ubde="$d/pool2.img" ubdf="$d/pool3.img" ubdg="$d/pool4.img" \
    ubdh="$d/logw.img" \
    seccomp=on mem="$(shard_mem $n)" con0=fd:0,fd:1 con=null > "$d/boot.out" 2>&1 &
  PID[$n]=$!; CURTEST[$n]=""; CURSINCE[$n]=$(date +%s)
}
comp_tests(){ grep -hoE '^[bg][a-z]*/[0-9]+ +([0-9]+s|.*not run)' "$BASE/shards/$1"/results/run.log* 2>/dev/null | grep -oE '^[bg][a-z]*/[0-9]+'; }
curtest(){ local l; l=$(tail -1 "$BASE/shards/$1/results/run.log" 2>/dev/null); echo "$l"|grep -qE '[0-9]+s *$|not run' && echo "" || echo "$l"|grep -oE '^[bg][a-z]*/[0-9]+'; }

# Return a dead lane's claimed-but-unfinished items to their queues. The item
# holding the culprit test: slim lane + first offense -> front of qbig
# (memory-shaped failures self-heal on a fat lane); else blacklist.
requeue_lane(){ local n=$1 bad=$2 reason=$3
  local m t comp
  comp=$(comp_tests $n | sort -u)
  for m in "$QR"/claimed/*.$n; do
    [ -f "$m" ] || continue
    t=$(cat "$m")
    if echo "$comp" | grep -qx "$t"; then mv "$m" "$QR/done/$(basename "$m")"; continue; fi
    if [ "$t" = "$bad" ]; then
      if [ "$reason" = crash ] && [ "$n" -lt "$SHARDS" ] && [[ "$m" != *retry* ]]; then
        mv "$m" "$QR/qbig/0000_retry_$(basename "$m" .$n)"
        log "lane $n: $t requeued to fat lane (crash retry)"
      else
        BL["$t"]=1; echo "$t" >> "$BLACKLIST_FILE"; echo "$t" >> "$BASE/results/$reason.txt"
        rm -f "$m"
        log "lane $n: $t blacklisted ($reason)"
      fi
    else
      # untouched claim: return to origin queue
      if [ "$n" -ge "$SHARDS" ]; then mv "$m" "$QR/qbig/$(basename "$m" .$n)"
      else mv "$m" "$QR/q/$(basename "$m" .$n)"; fi
    fi
  done
}
recover(){ local n=$1 bad=$2 reason=$3
  kill -9 "${PID[$n]}" 2>/dev/null; pkill -9 -f "$BASE/shards/$n/test.img" 2>/dev/null; sleep 1
  mv "$BASE/shards/$n/results/run.log" "$BASE/shards/$n/results/run.log.r${RESTARTS[$n]}" 2>/dev/null
  cp "$BASE/shards/$n/boot.out" "$BASE/shards/$n/boot.out.r${RESTARTS[$n]}" 2>/dev/null
  requeue_lane $n "$bad" "$reason"
  if [ "${RESTARTS[$n]}" -lt "$MAX_RESTARTS" ]; then
    RESTARTS[$n]=$(( RESTARTS[$n]+1 ))
    log "lane $n restart #${RESTARTS[$n]} ($reason recovery)"
    launch $n
  else
    DONE[$n]=1; log "lane $n retired (restarts=${RESTARTS[$n]})"
  fi
}

t0=$(date +%s)
for ((n=0;n<TOT;n++)); do DONE[$n]=0; RESTARTS[$n]=0; launch $n; done
log "lanes launched; monitoring..."

while :; do
  active=0
  for ((n=0;n<TOT;n++)); do
    [ "${DONE[$n]}" = 1 ] && continue
    if ! kill -0 "${PID[$n]}" 2>/dev/null; then
      if grep -q 'LANE.*DONE' "$BASE/shards/$n/boot.out" 2>/dev/null; then
        DONE[$n]=1; log "lane $n finished cleanly (completed=$(comp_tests $n|sort -u|wc -l))"
        requeue_lane $n "" clean   # safety: return any stray claims
      else
        ct=$(curtest $n)
        log "lane $n CRASHED on ${ct:-?} -> recover"
        recover $n "$ct" crash
      fi
      continue
    fi
    active=1
    ct=$(curtest $n); now=$(date +%s)
    if [ "${RSS_SAMPLE:-1}" = 1 ] && [ -n "$ct" ]; then
      rss=$(awk '/VmRSS/{print $2}' /proc/${PID[$n]}/status 2>/dev/null)
      [ -n "$rss" ] && echo "$ct $rss" >> "$BASE/results/rss-samples.txt"
    fi
    [ "$ct" != "${CURTEST[$n]}" ] && { CURTEST[$n]="$ct"; CURSINCE[$n]=$now; }
    local_stall=$STALL; [ "$n" -ge "$SHARDS" ] && local_stall=$STALL_BIG
    if [ -n "$ct" ] && [ $((now-${CURSINCE[$n]})) -ge $local_stall ]; then
      if [ $((now-${CURSINCE[$n]})) -ge $((4*local_stall)) ]; then
        log "lane $n clock jump ($((now-${CURSINCE[$n]}))s) — host suspend? resetting timer for $ct"
        CURSINCE[$n]=$now
      else
        log "lane $n STALLED on $ct for $((now-${CURSINCE[$n]}))s -> recover"
        recover $n "$ct" hang
      fi
    fi
  done
  [ "$active" = 0 ] && break
  sleep "$POLL"
done
WALL=$(( $(date +%s)-t0 ))

# Harvest per-test durations into the cumulative times DB (newest wins).
{ cat "$TIMES_DB"
  grep -rhoE '^[bg][a-z]*/[0-9]+ +[0-9]+s *$' "$BASE"/shards/*/results/run.log* 2>/dev/null \
    | awk '{gsub(/s$/,"",$2); print $1, $2}'
} | awk '{v[$1]=$2} END{for (t in v) print t, v[t]}' | sort > "$TIMES_DB.new" \
  && mv "$TIMES_DB.new" "$TIMES_DB"
log "times DB updated: $(wc -l < "$TIMES_DB") tests"
if [ -s "$BASE/results/rss-samples.txt" ]; then
  { cat "$BASE/results/rss-per-test.txt" 2>/dev/null
    cat "$BASE/results/rss-samples.txt"
  } | awk '{if ($2+0 > m[$1]) m[$1]=$2+0} END{for (t in m) print t, m[t]}' \
    | sort > "$BASE/results/rss-per-test.new" \
    && mv "$BASE/results/rss-per-test.new" "$BASE/results/rss-per-test.txt" \
    && rm -f "$BASE/results/rss-samples.txt"
  log "rss-per-test DB: $(wc -l < "$BASE/results/rss-per-test.txt") tests"
fi

log "=== AGGREGATE (wall ${WALL}s) ==="
tot=0; pass=0; fail=0; nr=0; failed=""
for ((n=0;n<TOT;n++)); do
  logs="$BASE/shards/$n"/results/run.log*
  p=$(grep -hcE '^[bg][a-z]*/[0-9]+ +[0-9]+s *$' $logs 2>/dev/null | paste -sd+ | bc 2>/dev/null); p=${p:-0}
  nrn=$(grep -hcE 'not run' $logs 2>/dev/null | paste -sd+ | bc 2>/dev/null); nrn=${nrn:-0}
  fl=$(grep -hoE '^[bg][a-z]*/[0-9]+' <(grep -hE 'output mismatch|\[failed' $logs 2>/dev/null) | sort -u)
  fn=$(echo "$fl"|grep -cE '^[bg]'); pass=$((pass+p)); nr=$((nr+nrn)); fail=$((fail+fn))
  [ -n "$fl" ] && failed="$failed $fl"
done
to=$(grep -rhoE '^[bg][a-z]*/[0-9]+ +\[failed, exit status 124\]' "$BASE"/shards/*/results/run.log* 2>/dev/null | grep -oE '^[bg][a-z]*/[0-9]+' | sort -u | wc -l)
echo "TOTAL: pass=$pass notrun=$nr failed=$fail (incl ~$to timeout) wall=${WALL}s"
echo "QUEUE: leftover q=$(ls "$QR/q" 2>/dev/null|wc -l) qbig=$(ls "$QR/qbig" 2>/dev/null|wc -l) claimed=$(ls "$QR/claimed" 2>/dev/null|wc -l) (all 0 = fully drained)"
echo "BLACKLIST: $(grep -cE '^[bg]' "$BLACKLIST_FILE") = hangs:$(sort -u "$BASE/results/hang.txt" 2>/dev/null|grep -cE '^[bg]') + crashes:$(sort -u "$BASE/results/crash.txt" 2>/dev/null|grep -cE '^[bg]')"
echo "HANGS: $(sort -u "$BASE/results/hang.txt" 2>/dev/null|grep -hE '^[bg]'|tr '\n' ' ')"
echo "CRASHES: $(sort -u "$BASE/results/crash.txt" 2>/dev/null|grep -hE '^[bg]'|tr '\n' ' ')"
if [ -n "$failed" ]; then
  FAILED_SET=$(echo $failed | tr ' ' '\n' | sort -u)
  echo "FAILURES(raw):$(echo "$FAILED_SET" | tr '\n' ' ')"
  if [ "${RETRY_SOLO:-1}" = 1 ]; then
    log "solo-retry lane: $(echo "$FAILED_SET" | wc -l) failed tests"
    d="$BASE/shards/retry"; rm -rf "$d"; mkdir -p "$d/results"
    echo "$FAILED_SET" > "$d/RUN_ARGS"
    truncate -s 64M "$d/dummy.img"
    truncate -s "$IMG_SIZE_BIG" "$d/test.img" "$d/scratch.img" \
      "$d/pool1.img" "$d/pool2.img" "$d/pool3.img" "$d/pool4.img" "$d/logw.img"
    "$KERNEL" rootfstype=hostfs rootflags="$ROOTFS" rw init="/shard-init.sh" shard=retry \
      ubda="$d/dummy.img" ubdb="$d/test.img" ubdc="$d/scratch.img" \
      ubdd="$d/pool1.img" ubde="$d/pool2.img" ubdf="$d/pool3.img" ubdg="$d/pool4.img" \
      ubdh="$d/logw.img" \
      seccomp=on mem="$MEM_BIG" con0=fd:0,fd:1 con=null > "$d/boot.out" 2>&1
    solo_fail=$(grep -hoE '^[bg][a-z]*/[0-9]+' <(grep -hE 'output mismatch|\[failed' "$d/results/run.log" 2>/dev/null) | sort -u)
    confirmed=$(comm -12 <(echo "$FAILED_SET") <(echo "$solo_fail"))
    flaky=$(comm -23 <(echo "$FAILED_SET") <(echo "$solo_fail"))
    echo "FAILURES(confirmed-solo):$(echo $confirmed | tr '\n' ' ')"
    echo "LOAD-FLAKY(passed-solo):$(echo $flaky | tr '\n' ' ')"
  fi
fi
