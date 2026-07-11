#!/bin/bash
# dev-check.sh — staged btrfs test feedback for kernel developers.
#
# Stages (each gates the next; first failure stops the pipeline):
#   smoke     ~1 min   20 fastest tests, one per subsystem group
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
KERNEL="${KERNEL:?set KERNEL=/path/to/uml/linux}"
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
  local list=$1 label=$2 slim=${3:-8} big=${4:-3}
  local bl="$R/devcheck-blacklist.txt"; cp "$EXCLUDE" "$bl"
  log "stage '$label': $(grep -cvE '^#|^\s*$' "$list") tests"
  BASE="$BASE" KERNEL="$KERNEL" LIST="$list" BLACKLIST="$bl" \
    SHARDS=$slim BIG_SHARDS=$big STALL=600 POLL=10 \
    bash "$SCRIPTDIR/run-supervised.sh" > "$R/devcheck-$label.out" 2>&1
  local line; line=$(grep '^TOTAL:' "$R/devcheck-$label.out" | tail -1)
  log "stage '$label': $line"
  if grep -q '^FAILURES:' "$R/devcheck-$label.out"; then
    log "stage '$label' FAILURES: $(grep '^FAILURES:' "$R/devcheck-$label.out" | tail -1 | cut -d: -f2)"
    return 1
  fi
  return 0
}

rc=0
case "$STAGE" in
smoke|all)
  run_list "$R/smoke.txt" smoke 4 0 || { log "SMOKE FAILED — stop"; exit 1; }
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
