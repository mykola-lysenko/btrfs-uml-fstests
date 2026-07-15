#!/bin/bash
# Supervised sharded xfstests runner with stall detection + recovery.
#
# Each shard is one UML running ./check over its slice, serially. A test that
# wedges in uninterruptible (D) kernel state can't be killed by the per-test
# timeout, so it stalls the whole shard. This supervisor watches each shard; if
# it sits on one test longer than STALL seconds (i.e. past the per-test timeout,
# so it's a true hang), it kills the shard, blacklists that test, and relaunches
# the shard with only its REMAINING tests. Results accumulate across restarts.
#
# Scheduling (v2):
#  - LPT assignment: tests sorted by known duration (TIMES_DB, harvested from
#    every run) land on the least-loaded shard; unknown tests assume the median.
#  - Memory tiering: tests listed in BIGMEM run only on BIG_SHARDS fat shards
#    (MEM_BIG); everything else on SHARDS slim shards (MEM). Prevents the
#    host-overcommit SIGBUS "crashes" that memory-hungry stress tests caused.
#  - Results of a previous run are archived (results/archive-*/), never deleted.
set -uo pipefail
BASE="${BASE:-$HOME/uml-smoke}"
SHARDS="${SHARDS:-8}"                 # slim shards
BIG_SHARDS="${BIG_SHARDS:-3}"         # fat shards for memory-hungry tests
TOT=$((SHARDS+BIG_SHARDS))
KERNEL="${KERNEL:-$BASE/linux-mainline/linux}"
LIST="${LIST:-$BASE/results/quick-all.txt}"
BLACKLIST_FILE="${BLACKLIST:-$BASE/results/blacklist.txt}"
MEM="${MEM:-1500M}"; MEM_BIG="${MEM_BIG:-3000M}"
IMG_SIZE="${IMG_SIZE:-3G}"; IMG_SIZE_BIG="${IMG_SIZE_BIG:-8G}"; INIT="/shard-init.sh"
TIMES_DB="${TIMES_DB:-$BASE/results/times-db.txt}"
BIGMEM_FILE="${BIGMEM:-$BASE/results/bigmem.txt}"
# Memory victims land here instead of the blacklist: they are re-run on the fat
# retry lane so a memory-tier miscalibration can never silently cost coverage.
DEFERRED_FILE="$BASE/results/deferred.txt"
ROOTFS="$BASE/rootfs-xfs"
# STALL must exceed the in-guest per-test timeout (900s in shard-init) so the
# timeout fails a slow test cleanly before the supervisor calls it a hang.
STALL="${STALL:-1000}"; STALL_BIG="${STALL_BIG:-1800}"; POLL="${POLL:-15}"; MAX_RESTARTS="${MAX_RESTARTS:-8}"
log(){ echo "[$(date '+%H:%M:%S')] $*"; }

declare -A BL
BL[__none__]=1; unset 'BL[__none__]'
touch "$BLACKLIST_FILE" "$TIMES_DB" "$BIGMEM_FILE"
: > "$DEFERRED_FILE"
while read -r t; do [ -n "$t" ] && BL["$t"]=1; done < <(grep -vE '^#|^\s*$' "$BLACKLIST_FILE")
mapfile -t ALL < <(grep -vE '^#|^\s*$' "$LIST")
TESTS=(); for t in "${ALL[@]}"; do [ -n "${BL[$t]:-}" ] || TESTS+=("$t"); done
log "${#TESTS[@]} tests (of ${#ALL[@]}) after blacklist(${#BL[@]}); $SHARDS slim + $BIG_SHARDS big shards; stall=${STALL}s"

# Archive previous run's results (never lose per-test times / out.bads).
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
for ((n=0;n<TOT;n++)); do mkdir -p "$BASE/shards/$n/results"; : > "$BASE/shards/$n/RUN_ARGS"; done

# LPT assignment (python: sorts by known time desc, greedy least-loaded shard;
# bigmem tests only onto the fat shards [SHARDS..TOT), others onto [0..SHARDS)).
# NOTE: the test list goes via a file — the heredoc already occupies stdin.
printf '%s\n' "${TESTS[@]}" > "$BASE/shards/.alltests"
python3 - "$TIMES_DB" "$BIGMEM_FILE" "$SHARDS" "$BIG_SHARDS" "$BASE/shards" <<'PY'
import sys
db_f, bm_f, slim, big, outdir = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
times = {}
for line in open(db_f):
    p = line.split()
    if len(p) == 2 and p[1].isdigit(): times[p[0]] = int(p[1])
bigmem = set(l.strip() for l in open(bm_f) if l.strip() and not l.startswith('#'))
tests = [l.strip() for l in open(outdir + "/.alltests") if l.strip()]
known = sorted(times.values())
med = known[len(known)//2] if known else 15
def lpt(items, shard_ids):
    load = {s: 0 for s in shard_ids}
    for t in sorted(items, key=lambda t: -times.get(t, med)):
        s = min(load, key=load.get)
        load[s] += times.get(t, med)
        open(f"{outdir}/{s}/RUN_ARGS", "a").write(t + "\n")
    return load
slim_ids = list(range(slim)); big_ids = list(range(slim, slim + big))
l1 = lpt([t for t in tests if t not in bigmem], slim_ids)
l2 = lpt([t for t in tests if t in bigmem], big_ids) if big else {}
pl = lambda d: " ".join(f"{k}:{v}s" for k, v in sorted(d.items()))
print(f"LPT loads slim: {pl(l1)}")
if l2: print(f"LPT loads big:  {pl(l2)}")
PY

declare -A PID DONE RESTARTS CURTEST CURSINCE
shard_mem(){ [ "$1" -ge "$SHARDS" ] && echo "$MEM_BIG" || echo "$MEM"; }
launch(){ local n=$1 d="$BASE/shards/$1"
  # image size follows the tier: slim shards keep small images (ENOSPC-fill
  # tests finish fast, slim guests stay within memory); fat shards get big
  # images for the genuinely large tests.
  local isz; isz=$([ "$n" -ge "$SHARDS" ] && echo "$IMG_SIZE_BIG" || echo "$IMG_SIZE")
  truncate -s 64M "$d/dummy.img"; truncate -s "$isz" "$d/test.img" "$d/scratch.img"
  # extra scratch-pool devices (sparse) -> guest enables SCRATCH_DEV_POOL
  truncate -s "$isz" "$d/pool1.img" "$d/pool2.img" "$d/pool3.img" "$d/pool4.img" "$d/logw.img"
  "$KERNEL" rootfstype=hostfs rootflags="$ROOTFS" rw init="$INIT" shard="$n" \
    ubda="$d/dummy.img" ubdb="$d/test.img" ubdc="$d/scratch.img" \
    ubdd="$d/pool1.img" ubde="$d/pool2.img" ubdf="$d/pool3.img" ubdg="$d/pool4.img" \
    ubdh="$d/logw.img" \
    seccomp=on mem="$(shard_mem $n)" con0=fd:0,fd:1 con=null > "$d/boot.out" 2>&1 &
  PID[$n]=$!; CURTEST[$n]=""; CURSINCE[$n]=$(date +%s)
}
# completed/running derived from ALL run.log parts in the shard dir
# completed = any per-test verdict line: pass (Ns), notrun, or ANY failure
# form. Failures must count as completed or crash recovery re-runs them.
comp_tests(){ grep -hoE '^[bg][a-z]*/[0-9]+ +([0-9]+s|.*not run|.*output mismatch|.*\[failed|.*_check_[a-z_]*)' "$BASE/shards/$1"/results/run.log* 2>/dev/null | grep -oE '^[bg][a-z]*/[0-9]+'; }
# every failure form ./check prints on the test's own line: golden-output
# mismatch, nonzero exit, dmesg hit, post-test fsck inconsistency
FAIL_RE='output mismatch|\[failed|_check_dmesg|_check_[a-z_]*filesystem|inconsistent'
curtest(){ local l; l=$(tail -1 "$BASE/shards/$1/results/run.log" 2>/dev/null); echo "$l"|grep -qE '[0-9]+s *$|not run' && echo "" || echo "$l"|grep -oE '^[bg][a-z]*/[0-9]+'; }
# Why did a guest die? The console tells us, and the answer decides whether the
# running test deserves the blame:
#   shm-sigbus — host /dev/shm is exhausted. Guest RAM lives in /dev/shm (see
#                wsl2-memory-cap), so the page fault the guest cannot satisfy
#                surfaces as "Kernel mode signal 7". This is a host budget
#                error; the test running when it landed is an innocent
#                bystander and must not be blacklisted for it.
#   oom        — the guest kernel ran out of its own mem=: this test really
#                does need the fat tier.
#   crash      — a genuine kernel bug. Blacklisting it is the entire point.
death_kind(){ local f="$BASE/shards/$1/boot.out"
  grep -q 'Kernel mode signal 7' "$f" 2>/dev/null && { echo shm-sigbus; return; }
  grep -qE 'Out of memory: Killed|oom-kill:|Out of memory and no killable' "$f" 2>/dev/null \
    && { echo oom; return; }
  echo crash
}
# recover a shard (from a stall OR a crash): sideline the bad test, save this
# attempt's results, and relaunch with the remaining tests. A memory victim is
# sidelined from THIS lane but deferred to the fat retry lane, never blacklisted.
recover(){ local n=$1 bad=$2 reason=$3
  if [ -n "$bad" ] && [ -z "${BL[$bad]:-}" ]; then
    BL["$bad"]=1                       # skip on this lane whatever the reason
    echo "$bad" >> "$BASE/results/$reason.txt"
    case "$reason" in
      oom|shm-sigbus)                  # memory victim: keep the coverage
        echo "$bad" >> "$DEFERRED_FILE"
        [ "$reason" = oom ] && echo "$bad" >> "$BIGMEM_FILE" ;;
      *) echo "$bad" >> "$BLACKLIST_FILE" ;;
    esac
  fi
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
for ((n=0;n<TOT;n++)); do DONE[$n]=0; RESTARTS[$n]=0; [ -s "$BASE/shards/$n/RUN_ARGS" ] && launch $n || DONE[$n]=1; done
log "launched; monitoring..."

while :; do
  active=0
  for ((n=0;n<TOT;n++)); do
    [ "${DONE[$n]}" = 1 ] && continue
    if ! kill -0 "${PID[$n]}" 2>/dev/null; then
      if grep -q 'SHARD.*DONE' "$BASE/shards/$n/boot.out" 2>/dev/null; then
        DONE[$n]=1; log "shard $n finished cleanly (completed=$(comp_tests $n|sort -u|wc -l))"
      else
        ct=$(curtest $n); kind=$(death_kind $n)
        case "$kind" in
          shm-sigbus) log "shard $n SIGBUS on ${ct:-?} — host /dev/shm exhausted, NOT a test bug; deferring to fat retry lane. Lane budget is too big for $(df -h --output=size /dev/shm|tail -1|tr -d ' ')." ;;
          oom)        log "shard $n guest-OOM on ${ct:-?} — promoting to BIGMEM (fat tier), deferring to fat retry lane" ;;
          crash)      log "shard $n CRASHED on ${ct:-?} (completed=$(comp_tests $n|sort -u|wc -l)) -> blacklist + recover" ;;
        esac
        recover $n "$ct" "$kind"
      fi
      continue
    fi
    active=1
    ct=$(curtest $n); now=$(date +%s)
    # RSS sampling: VmRSS of the UML main process, tagged with the running
    # test — feeds data-driven memory-tier sizing (max-RSS-per-test).
    if [ "${RSS_SAMPLE:-1}" = 1 ] && [ -n "$ct" ]; then
      rss=$(awk '/VmRSS/{print $2}' /proc/${PID[$n]}/status 2>/dev/null)
      [ -n "$rss" ] && echo "$ct $rss" >> "$BASE/results/rss-samples.txt"
    fi
    [ "$ct" != "${CURTEST[$n]}" ] && { CURTEST[$n]="$ct"; CURSINCE[$n]=$now; }
    # fat shards host the known-slow/big tests: give them a longer stall
    local_stall=$STALL; [ "$n" -ge "$SHARDS" ] && local_stall=$STALL_BIG
    if [ -n "$ct" ] && [ $((now-${CURSINCE[$n]})) -ge $local_stall ]; then
      # A delta far beyond STALL means the host slept (wall clock jumped),
      # not that the test hung — reset the timer instead of blacklisting.
      if [ $((now-${CURSINCE[$n]})) -ge $((4*local_stall)) ]; then
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

# Harvest per-test durations into the cumulative times DB (newest wins).
{ cat "$TIMES_DB"
  grep -rhoE '^[bg][a-z]*/[0-9]+ +[0-9]+s *$' "$BASE"/shards/*/results/run.log* 2>/dev/null \
    | awk '{gsub(/s$/,"",$2); print $1, $2}'
} | awk '{v[$1]=$2} END{for (t in v) print t, v[t]}' | sort > "$TIMES_DB.new" \
  && mv "$TIMES_DB.new" "$TIMES_DB"
log "times DB updated: $(wc -l < "$TIMES_DB") tests"

# Aggregate RSS samples: keep the max KB seen per test (merged across runs).
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
  fl=$(grep -hoE '^[bg][a-z]*/[0-9]+' <(grep -hE "$FAIL_RE" $logs 2>/dev/null) | sort -u)
  fn=$(echo "$fl"|grep -cE '^[bg]'); pass=$((pass+p)); nr=$((nr+nrn)); fail=$((fail+fn))
  [ -n "$fl" ] && failed="$failed $fl"
done
to=$(grep -rhoE '^[bg][a-z]*/[0-9]+ +\[failed, exit status 124\]' "$BASE"/shards/*/results/run.log* 2>/dev/null | grep -oE '^[bg][a-z]*/[0-9]+' | sort -u | wc -l)
echo "TOTAL: pass=$pass notrun=$nr failed=$fail (incl ~$to timeout) wall=${WALL}s"
echo "BLACKLIST: $(grep -cE '^[bg]' "$BLACKLIST_FILE") = hangs:$(sort -u "$BASE/results/hang.txt" 2>/dev/null|grep -cE '^[bg]') + crashes:$(sort -u "$BASE/results/crash.txt" 2>/dev/null|grep -cE '^[bg]')"
echo "HANGS: $(sort -u "$BASE/results/hang.txt" 2>/dev/null|grep -hE '^[bg]'|tr '\n' ' ')"
echo "CRASHES: $(sort -u "$BASE/results/crash.txt" 2>/dev/null|grep -hE '^[bg]'|tr '\n' ' ')"
DEFERRED_SET=$(grep -hE '^[bg]' "$DEFERRED_FILE" 2>/dev/null | sort -u)
[ -n "$DEFERRED_SET" ] && echo "DEFERRED(memory-victims):$(echo $DEFERRED_SET | tr '\n' ' ')"
if [ -n "$failed" ] || [ -n "$DEFERRED_SET" ]; then
  FAILED_SET=$(echo $failed | tr ' ' '\n' | grep -E '^[bg]' | sort -u)
  [ -n "$FAILED_SET" ] && echo "FAILURES(raw):$(echo "$FAILED_SET" | tr '\n' ' ')"
  if [ "${RETRY_SOLO:-1}" = 1 ]; then
    # Re-run every failure serially in ONE fresh UML: what passes solo was
    # load-sensitive (environmental), what fails again is a real failure.
    # This lane is fat (MEM_BIG), so it doubles as the recovery lane for tests
    # their own lane could not give enough memory: a memory-tier miscalibration
    # costs wall-clock here, never coverage.
    RERUN_SET=$(printf '%s\n%s\n' "$FAILED_SET" "$DEFERRED_SET" | grep -E '^[bg]' | sort -u)
    log "solo-retry lane (mem=$MEM_BIG): $(echo "$RERUN_SET"|grep -c .) tests = $(echo "$FAILED_SET"|grep -c .) failed + $(echo "$DEFERRED_SET"|grep -c .) memory-deferred"
    d="$BASE/shards/retry"; rm -rf "$d"; mkdir -p "$d/results"
    echo "$RERUN_SET" > "$d/RUN_ARGS"
    truncate -s 64M "$d/dummy.img"
    truncate -s "$IMG_SIZE_BIG" "$d/test.img" "$d/scratch.img" \
      "$d/pool1.img" "$d/pool2.img" "$d/pool3.img" "$d/pool4.img" "$d/logw.img"
    "$KERNEL" rootfstype=hostfs rootflags="$ROOTFS" rw init="$INIT" shard=retry \
      ubda="$d/dummy.img" ubdb="$d/test.img" ubdc="$d/scratch.img" \
      ubdd="$d/pool1.img" ubde="$d/pool2.img" ubdf="$d/pool3.img" ubdg="$d/pool4.img" \
      ubdh="$d/logw.img" \
      seccomp=on mem="$MEM_BIG" con0=fd:0,fd:1 con=null > "$d/boot.out" 2>&1
    solo_fail=$(grep -hoE '^[bg][a-z]*/[0-9]+' <(grep -hE "$FAIL_RE" "$d/results/run.log" 2>/dev/null) | sort -u)
    if [ -n "$FAILED_SET" ]; then
      confirmed=$(comm -12 <(echo "$FAILED_SET") <(echo "$solo_fail"))
      flaky=$(comm -23 <(echo "$FAILED_SET") <(echo "$solo_fail"))
      echo "FAILURES(confirmed-solo):$(echo $confirmed | tr '\n' ' ')"
      echo "LOAD-FLAKY(passed-solo):$(echo $flaky | tr '\n' ' ')"
    fi
    if [ -n "$DEFERRED_SET" ]; then
      # A deferred test that passes on the fat lane got its coverage back and
      # only cost us time; one that still fails needs a human.
      drec=$(comm -23 <(echo "$DEFERRED_SET") <(echo "$solo_fail"))
      dfail=$(comm -12 <(echo "$DEFERRED_SET") <(echo "$solo_fail"))
      echo "DEFERRED(recovered-on-fat):$(echo $drec | tr '\n' ' ')"
      echo "DEFERRED(still-failing):$(echo $dfail | tr '\n' ' ')"
    fi
  elif [ -n "$DEFERRED_SET" ]; then
    echo "WARNING: RETRY_SOLO=0 and $(echo "$DEFERRED_SET"|grep -c .) tests were memory-deferred — they did NOT run. Coverage is incomplete."
  fi
fi
