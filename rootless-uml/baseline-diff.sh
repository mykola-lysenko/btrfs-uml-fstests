#!/bin/bash
# baseline-diff.sh — diff one sweep's failures against the committed per-fs
# known-failure baseline (results/baseline-<fs>-confirmed.txt in the repo).
#
# The baseline is the triaged, committed list of tests EXPECTED to fail on
# this rig (environment/tooling limitations, pending-fix clusters). The
# contract of every sweep is then:
#   failure NOT in baseline  -> NEW-FAILURES, regression alarm, exit 1
#   baseline test that PASSES -> FIXED, progress to fold into the baseline
#   failure in baseline       -> KNOWN, not a gate concern
#
# Usage: [FSTYP=btrfs] [BASE=~/uml-smoke] baseline-diff.sh <run-supervised.out> [baseline]
#   run-supervised.out : captured output of run-supervised.sh (dev-check's
#                        devcheck-<stage>.out); failures are taken from its
#                        FAILURES(confirmed-solo) line — the solo-retry lane
#                        already filtered load-flakes — falling back to
#                        FAILURES(raw) for runs with RETRY_SOLO=0.
#   Passes are harvested from $BASE/shards/*/results/run.log* of that run,
#   so run this before the next sweep archives the shards.
# Exit: 0 = no new failures; 1 = new failures; 2 = usage/data error.
set -uo pipefail
SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="${BASE:-$HOME/uml-smoke}"
FSTYP="${FSTYP:-btrfs}"
OUT="${1:?usage: baseline-diff.sh <run-supervised-output> [baseline]}"
BASELINE="${2:-$SCRIPTDIR/../results/baseline-$FSTYP-confirmed.txt}"
[ -f "$OUT" ] || { echo "baseline-diff: no run output at $OUT"; exit 2; }
[ -f "$BASELINE" ] || { echo "baseline-diff: no baseline for $FSTYP at $BASELINE"; exit 2; }
grep -q '^TOTAL:' "$OUT" || { echo "baseline-diff: $OUT has no TOTAL line (runner died?)"; exit 2; }

TESTRE='^[begx][a-z0-9]*/[0-9]+'
line=$(grep -E '^FAILURES\(confirmed-solo\):' "$OUT" | tail -1)
[ -z "$line" ] && line=$(grep -E '^FAILURES\(raw\):' "$OUT" | tail -1)
failed=$(echo "${line#*:}" | tr ' ' '\n' | grep -E "$TESTRE" | sort -u)
base=$(grep -vE '^#|^[[:space:]]*$' "$BASELINE" | grep -E "$TESTRE" | sort -u)
passed=$(grep -hE "$TESTRE +[0-9]+s *$" "$BASE"/shards/*/results/run.log* 2>/dev/null \
         | grep -oE "$TESTRE" | sort -u)

new=$(comm -23 <(printf '%s\n' "$failed") <(printf '%s\n' "$base") | grep -E "$TESTRE")
known=$(comm -12 <(printf '%s\n' "$failed") <(printf '%s\n' "$base") | grep -E "$TESTRE")
# FIXED = in baseline, passed this sweep, and not also among its failures
# (a test can appear in both when a flake passed one lane and failed another).
fixed=$(comm -12 <(printf '%s\n' "$base") <(printf '%s\n' "$passed") \
        | comm -23 - <(printf '%s\n' "$failed") | grep -E "$TESTRE")

cnt(){ printf '%s\n' "$1" | grep -cE "$TESTRE"; }
echo "BASELINE-DIFF($FSTYP): new=$(cnt "$new") known=$(cnt "$known") fixed=$(cnt "$fixed") (baseline $(cnt "$base") entries)"
[ -n "$new" ]   && echo "NEW-FAILURES: $(echo $new | tr '\n' ' ')"
[ -n "$fixed" ] && echo "FIXED(fold into baseline): $(echo $fixed | tr '\n' ' ')"
[ -n "$known" ] && echo "KNOWN(in baseline): $(echo $known | tr '\n' ' ')"
[ -z "$new" ]
