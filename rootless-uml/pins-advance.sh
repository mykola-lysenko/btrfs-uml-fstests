#!/bin/bash
# pins-advance.sh — mechanize the weekly PINS advance ritual.
#
#   ./pins-advance.sh              # check: has any pinned branch moved?
#   ./pins-advance.sh advance KERNEL_TRIFS     # advance one kernel pin
#   ./pins-advance.sh advance KERNEL_BTRFSTIP
#
# advance resolves the pinned branch's current tip via the GitHub API,
# downloads and builds the kernel BY SHA (reproducible — no moving-branch
# tarballs), rewrites PINS (SHA, NAME, PIN_DATE), and prints the ritual
# checklist. It does NOT run sweeps or touch baselines — those steps need
# a human verdict per the plan ("never advance mid-investigation").
# XFSTESTS advance is deliberately manual (toolchain rebuild + redeploy);
# check mode still reports when it has moved.
set -euo pipefail
SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PINSFILE="$SCRIPTDIR/PINS"
# shellcheck source=PINS
. "$PINSFILE"
log(){ echo "[pins] $*"; }

resolve(){ # $1 repo  $2 ref -> 40-hex tip sha on stdout, or fail
  curl -sf "https://api.github.com/repos/$1/commits/$2" \
    | sed -n 's/^  "sha": "\([0-9a-f]\{40\}\)".*/\1/p' | head -1 | grep .
}

check_one(){ # $1 pin-prefix
  local repo ref sha tip state
  repo=$(eval echo "\$${1}_REPO"); ref=$(eval echo "\$${1}_REF")
  sha=$(eval echo "\$${1}_SHA")
  tip=$(resolve "$repo" "$ref") || { log "$1: API resolve FAILED ($repo $ref)"; return 1; }
  state=current; [ "$tip" != "$sha" ] && state=MOVED
  log "$1: $repo $ref pinned=${sha:0:12} upstream=${tip:0:12} [$state]"
  [ "$state" = current ]
}

case "${1:-check}" in
check)
  rc=0
  for p in KERNEL_TRIFS KERNEL_BTRFSTIP XFSTESTS; do check_one "$p" || rc=1; done
  exit $rc ;;
advance)
  PIN="${2:?usage: pins-advance.sh advance KERNEL_TRIFS|KERNEL_BTRFSTIP}"
  case "$PIN" in KERNEL_TRIFS|KERNEL_BTRFSTIP) ;; *)
    echo "only kernel pins auto-advance (XFSTESTS is a manual toolchain rebuild)"; exit 2;;
  esac
  repo=$(eval echo "\$${PIN}_REPO"); ref=$(eval echo "\$${PIN}_REF")
  old=$(eval echo "\$${PIN}_SHA")
  tip=$(resolve "$repo" "$ref") || { log "API resolve failed"; exit 1; }
  [ "$tip" = "$old" ] && { log "$PIN already at upstream tip ${tip:0:12} — nothing to do"; exit 0; }
  stamp=$(date +%m%d)
  name="${ref}-${stamp}"
  log "$PIN: ${old:0:12} -> ${tip:0:12}; building linux-$name by SHA..."
  REPO="$repo" REF="$tip" NAME="$name" bash "$SCRIPTDIR/build-uml-kernel.sh"
  sed -i -e "s|^${PIN}_SHA=.*|${PIN}_SHA=$tip|" \
         -e "s|^${PIN}_NAME=.*|${PIN}_NAME=$name|" \
         -e "s|^PIN_DATE=.*|PIN_DATE=$(date +%F)|" "$PINSFILE"
  log "PINS updated. Ritual checklist (do these IN ORDER, quiet day only):"
  cat <<EOF
  1. deploy:   ./deploy.sh
  2. gate:     KERNEL=\$HOME/uml-smoke/linux-$name/linux ./dev-check.sh smoke
  3. sweeps:   serial full sweeps per fs on the new kernel (run-supervised)
  4. triage:   baseline-diff.sh on each sweep — investigate every NEW failure
  5. fold:     update results/baseline-*-confirmed.txt (FIXED out, triaged in)
  6. lists:    gen-smoke-list.sh with ARCHIVE=<this sweep> per fs
  7. commit:   PINS + baselines + lists together, one commit
EOF
  ;;
*)
  echo "usage: pins-advance.sh [check|advance <PIN>]"; exit 2 ;;
esac
