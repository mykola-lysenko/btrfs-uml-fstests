#!/bin/bash
# dev-check.sh — staged btrfs test feedback for kernel developers.
#
# Stages (each gates the next; first failure stops the pipeline):
#   smoke     ~2 min   tri-fs CI gate: ~20 fastest tests per fs, one per
#                      subsystem group, for each of btrfs, xfs, fuse.
#                      This is the rig's CI: any change under rootless-uml/,
#                      the rootfs, or xfstests-built must pass it before a
#                      full sweep. Smoke lists are curated confirmed-pass
#                      tests, so notrun>0 is a failure too (catches missing
#                      kernel configs, clobbered rootfs, lost harness bits).
#   targeted  ~2-5 min tests whose groups match the files you changed
#   quick     ~10 min  the full btrfs quick group
#   full      ~45 min  the full auto group (pre-submit gate)
#
# Usage:
#   KERNEL=~/uml-smoke/linux-mytree/linux ./dev-check.sh [--tree DIR] [--base REF] [STAGE]
#     STAGE: smoke|targeted|quick|full|all   (default: all = staged pipeline)
#     --tree DIR : kernel source tree to diff for targeted selection
#     --base REF : git ref to diff against (default: origin/master)
#
# Requires: rootless-uml pipeline set up (rootfs, xfstests-built, lists in
# $BASE/results). Uses run-supervised.sh for execution, so LPT scheduling,
# memory tiering, stall recovery, and the times DB all apply.
set -uo pipefail
SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="${BASE:-$HOME/uml-smoke}"
# KERNEL= is an explicit override used for every fs. Without it, each fs
# runs on its own pinned kernel from PINS (plan item 7) — btrfs sweeps
# btrfs for-next, xfs sweeps xfs for-next, fuse sweeps mainline.
KERNEL="${KERNEL:-}"
[ -f "$SCRIPTDIR/PINS" ] && . "$SCRIPTDIR/PINS"
kernel_for(){ # $1 fs -> kernel binary path ('' if unresolvable)
  if [ -n "$KERNEL" ]; then echo "$KERNEL"; return; fi
  local name=""
  case "$1" in
    btrfs) name="${KERNEL_BTRFS_NAME:-}";;
    xfs)   name="${KERNEL_XFS_NAME:-${KERNEL_BTRFS_NAME:-}}";;
    fuse)  name="${KERNEL_FUSE_NAME:-${KERNEL_BTRFS_NAME:-}}";;
  esac
  [ -n "$name" ] && echo "$BASE/linux-$name/linux" || echo ""
}
[ -n "$KERNEL" ] || [ -n "${KERNEL_BTRFS_NAME:-}" ] || \
  { echo "set KERNEL=/path/to/uml/linux (no PINS kernel names found)"; exit 1; }
TREE=""; BASEREF="origin/master"; STAGE="all"
while [ $# -gt 0 ]; do case "$1" in
  --tree) TREE="$2"; shift 2;;
  --base) BASEREF="$2"; shift 2;;
  *) STAGE="$1"; shift;;
esac; done
R="$BASE/results"
EXCLUDE="$R/exclude-known.txt"   # permanent excludes (e.g. btrfs/301 UML artifact)
touch "$EXCLUDE"
log(){ echo "[dev-check] $*"; }

# Deployed-state manifest (written by deploy.sh). Recorded with every gate
# run so a result can always be tied to an exact deployed file set.
if [ -f "$BASE/.deploy-manifest" ]; then
  log "deployed manifest: $(head -1 "$BASE/.deploy-manifest")"
else
  log "deployed manifest: UNMANAGED — run deploy.sh to bless the deployed set"
fi

# Map changed btrfs source files -> fstests groups.
groups_for_diff(){
  local tree=$1 baseref=$2
  git -C "$tree" diff --name-only "$baseref" -- 2>/dev/null | while read -r f; do
    case "$f" in
      fs/btrfs/send.c|fs/btrfs/send.h) echo send; echo snapshot;;
      fs/btrfs/qgroup.*) echo qgroup;;
      fs/btrfs/relocation.c|fs/btrfs/volumes.*) echo balance; echo volume; echo replace;;
      fs/btrfs/raid56.*) echo raid;;
      fs/btrfs/scrub.c) echo scrub;;
      fs/btrfs/compression.*|fs/btrfs/zstd.c|fs/btrfs/lzo.c|fs/btrfs/zlib.c) echo compress;;
      fs/btrfs/tree-log.*) echo log;;
      fs/btrfs/free-space-*|fs/btrfs/space-info.*) echo enospc;;
      fs/btrfs/reflink.*) echo clone; echo dedupe;;
      fs/btrfs/defrag.*) echo defrag;;
      fs/btrfs/verity.c) echo verity;;
      fs/btrfs/ioctl.c) echo ioctl;;
      fs/btrfs/extent-tree.c|fs/btrfs/extent_io.*|fs/btrfs/extent_map.*) echo rw; echo fiemap; echo punch;;
      fs/btrfs/inode.c|fs/btrfs/file.c) echo rw; echo mmap; echo prealloc;;
      fs/btrfs/*) echo metadata;;   # any other btrfs file: metadata sanity
    esac
  done | sort -u
}

run_list(){ # $1 list-file  $2 label  [$3 slim shards] [$4 big shards]
  # env: FS = fs under test (default btrfs); STRICT_NOTRUN=1 makes any
  # notrun a failure (for curated pass lists, where a skip means the
  # environment lost something: kernel config, rootfs bits, harness).
  local list=$1 label=$2 slim=${3:-8} big=${4:-3} fs="${FS:-btrfs}"
  local excl="$EXCLUDE"
  [ "$fs" != btrfs ] && { excl="$R/exclude-known-$fs.txt"; touch "$excl"; }
  local bl="$R/devcheck-blacklist.txt"; cp "$excl" "$bl"
  local kern; kern=$(kernel_for "$fs")
  [ -x "$kern" ] || { log "stage '$label': kernel not found/executable: $kern"; return 1; }
  log "stage '$label': $(grep -cvE '^#|^\s*$' "$list") tests [$fs] kernel=$(basename "$(dirname "$kern")")"
  BASE="$BASE" KERNEL="$kern" LIST="$list" BLACKLIST="$bl" FSTYP="$fs" \
    SHARDS=$slim BIG_SHARDS=$big STALL=600 POLL=10 \
    bash "$SCRIPTDIR/run-supervised.sh" > "$R/devcheck-$label.out" 2>&1
  local line; line=$(grep '^TOTAL:' "$R/devcheck-$label.out" | tail -1)
  if [ -z "$line" ]; then
    log "stage '$label': no TOTAL line — runner died (see $R/devcheck-$label.out)"
    return 1
  fi
  log "stage '$label': $line"
  # Zero-work green guard: a stage that executed fewer tests than listed is
  # a FAILURE even with failed=0 — guests that never boot, lost lists, and
  # scheduler bugs all present as a vacuous pass=0 "success" otherwise
  # (bit us three times: scratchpad list wipe, and the hosted lane's first
  # "green" run where UML executed nothing at all).
  local listed ran
  listed=$(grep -cvE '^#|^\s*$' "$list")
  ran=$(( $(sed -n 's/.*pass=\([0-9]*\).*/\1/p' <<<"$line") \
       + $(sed -n 's/.*notrun=\([0-9]*\).*/\1/p' <<<"$line") \
       + $(sed -n 's/.*failed=\([0-9]*\).*/\1/p' <<<"$line") ))
  # grep -c prints the 0 itself on no-match (and exits 1) — no || echo
  local blk; blk=$(grep -cvE '^#|^\s*$' "$bl" 2>/dev/null | head -1); blk=${blk:-0}
  if [ "$ran" -lt $((listed - blk)) ]; then
    log "stage '$label': only $ran of $listed listed tests produced a verdict (blacklisted<=$blk) — guests died or list lost (see $R/devcheck-$label.out and shard boot.out)"
    return 1
  fi
  # Parse failed= from the TOTAL line rather than grepping a FAILURES
  # marker: run-supervised prints FAILURES(raw)/(confirmed-solo), and the
  # old '^FAILURES:' grep matched neither — failures sailed through.
  local nf; nf=$(sed -n 's/.*failed=\([0-9]*\).*/\1/p' <<<"$line")
  # quick/full run real test groups where the triaged environment failures
  # in results/baseline-<fs>-confirmed.txt are expected: there the committed
  # baseline decides what gates (new failure = regression, known = pass,
  # baseline test passing = logged progress). Smoke/targeted lists are
  # curated confirmed-pass sets — any failure gates, no baseline applies.
  local blfile="$SCRIPTDIR/../results/baseline-$fs-confirmed.txt" brc=""
  if { [ "$label" = quick ] || [ "$label" = full ]; } && [ -f "$blfile" ]; then
    FSTYP=$fs BASE=$BASE bash "$SCRIPTDIR/baseline-diff.sh" \
      "$R/devcheck-$label.out" "$blfile" > "$R/devcheck-$label.baseline" 2>&1
    brc=$?
    while IFS= read -r bl; do log "stage '$label': $bl"; done < "$R/devcheck-$label.baseline"
  fi
  if [ -n "$nf" ] && [ "$nf" -gt 0 ]; then
    local solo=""
    if grep -qE '^FAILURES\(confirmed-solo\):' "$R/devcheck-$label.out"; then
      solo=$(grep -E '^FAILURES\(confirmed-solo\):' "$R/devcheck-$label.out" \
             | tail -1 | cut -d: -f2 | tr -d '[:space:]')
      soloran=1
    else
      soloran=0
    fi
    if [ "$brc" = 0 ]; then
      log "stage '$label': $nf failures, none new (known-baseline or load-flaky) — not gating"
    elif [ "$soloran" = 1 ] && [ -z "$solo" ]; then
      # The solo-retry lane reran every failure serially and all passed:
      # pure load-flakes. Smoke lists are curated confirmed-pass tests, so
      # trust the runner's own classification instead of failing the gate.
      log "stage '$label': $nf raw failure(s) all passed solo — load-flake, not gating"
    else
      log "stage '$label' FAILURES:$(grep -E '^FAILURES\((raw|confirmed-solo)\):' \
        "$R/devcheck-$label.out" | tail -1 | cut -d: -f2)"
      return 1
    fi
  fi
  if [ "${STRICT_NOTRUN:-0}" = 1 ]; then
    local nr; nr=$(sed -n 's/.*notrun=\([0-9]*\).*/\1/p' <<<"$line")
    if [ -n "$nr" ] && [ "$nr" -gt 0 ]; then
      log "stage '$label': $nr notrun on a curated pass list — environment regression (see $R/devcheck-$label.out)"
      return 1
    fi
  fi
  return 0
}

rc=0
case "$STAGE" in
smoke|all)
  # GATE_FS overrides which filesystems the gate covers. A fs whose
  # CONFIG_*_FS=y is provably absent from the kernel's .config is skipped
  # loudly (a btrfs-only dev tree is legitimate); if no .config is found
  # we run anyway and let STRICT_NOTRUN catch a config-less kernel.
  for fs in ${GATE_FS:-btrfs xfs fuse}; do
    case "$fs" in btrfs) slist="$R/smoke.txt"; copt=CONFIG_BTRFS_FS;;
                  xfs)   slist="$R/smoke-xfs.txt"; copt=CONFIG_XFS_FS;;
                  fuse)  slist="$R/smoke-fuse.txt"; copt=CONFIG_FUSE_FS;;
                  *) log "unknown GATE_FS entry: $fs"; exit 1;; esac
    [ -f "$slist" ] || { log "SMOKE($fs): $slist missing — run deploy.sh"; exit 1; }
    KCONFIG="$(dirname "$(kernel_for "$fs")")/.config"
    if [ -f "$KCONFIG" ] && ! grep -q "^$copt=y" "$KCONFIG"; then
      log "SMOKE($fs) SKIPPED: kernel lacks $copt=y ($KCONFIG)"
      continue
    fi
    FS=$fs STRICT_NOTRUN=1 run_list "$slist" "smoke-$fs" 4 0 \
      || { log "SMOKE($fs) FAILED — stop"; exit 1; }
  done
  [ "$STAGE" = smoke ] && exit 0 ;;&
targeted|all)
  if [ -n "$TREE" ]; then
    mapfile -t GRPS < <(groups_for_diff "$TREE" "$BASEREF")
    if [ "${#GRPS[@]}" -gt 0 ]; then
      log "changed-file groups: ${GRPS[*]}"
      awk -v gs="${GRPS[*]}" 'BEGIN{n=split(gs,g," ")}
        { for(i=2;i<=NF;i++) for(j=1;j<=n;j++) if($i==g[j]){print $1; next} }' \
        "$R/test-groups.txt" | sort -u > "$R/targeted.txt"
      run_list "$R/targeted.txt" targeted 6 2 || { log "TARGETED FAILED — stop"; exit 1; }
    else
      log "no btrfs source changes detected vs $BASEREF — skipping targeted"
    fi
  else
    log "no --tree given — skipping targeted"
  fi
  [ "$STAGE" = targeted ] && exit 0 ;;&
quick|all)
  run_list "$R/quick-all.txt" quick || { log "QUICK FAILED — stop"; exit 1; }
  [ "$STAGE" = quick ] && exit 0 ;;&
full|all)
  run_list "$R/auto-all.txt" full || rc=1 ;;
esac
[ $rc -eq 0 ] && log "ALL STAGES CLEAN — safe to submit" || log "FULL stage has failures — see $R/devcheck-full.out"
exit $rc
