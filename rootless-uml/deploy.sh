#!/bin/bash
# deploy.sh — sync the blessed rig file set from this repo to the deployed
# base, verify the environment invariants, and record a manifest hash that
# dev-check.sh logs with every gate run.
#
# Kills the repo-copy-vs-deployed-copy divergence class (qemu-init pool
# support, queue-init fuse branch both bit us). Direction discipline:
#   repo -> rig : guest init scripts, scheduler lists, xfstests patches
#   rig  -> repo: measured data (times DBs, sweep results) — never synced here
#
# Verifies (hard-fails on violation):
#   - rootfs /bin /sbin /lib /lib64 are symlinks (the dpkg -x tar-clobber class)
#   - every patches-xfstests/*.patch is applied in xfstests-built
#     (APPLY=1 hot-applies missing ones; default is fail + tell you)
#   - mount.fuse.fuse2fs and shard-init.sh deployed and executable
#
# Usage: [BASE=~/uml-smoke] [ROOTFS=$BASE/rootfs-xfs] [APPLY=1] ./deploy.sh
set -uo pipefail
SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="${BASE:-$HOME/uml-smoke}"
ROOTFS="${ROOTFS:-$BASE/rootfs-xfs}"
R="$BASE/results"
XT="$BASE/xfstests-built"
log(){ echo "[deploy] $*"; }
fail(){ echo "[deploy] FAIL: $*" >&2; exit 1; }
rc=0

[ -d "$ROOTFS" ] || fail "rootfs not found: $ROOTFS"
[ -d "$XT" ] || fail "xfstests-built not found: $XT"
mkdir -p "$R"

# Guest-side scripts, deployed to the rootfs root (UML PID1s and labs).
GUEST_SCRIPTS="shard-init.sh queue-init.sh qemu-init checkenv-init.sh
  fsxprobe-init.sh prof-init.sh validate033-init.sh smoke-init.sh
  xfstests-init.sh manual-297.sh manual-parity.sh"
# Scheduler input lists, deployed to $R. Measured data (times DBs,
# residual/baseline files) is intentionally NOT in this set.
LISTS="smoke.txt smoke-xfs.txt smoke-fuse.txt quick-all.txt quick-fast.txt
  quick-slow.txt auto-all.txt confirmed-fast.txt confirmed-slow.txt
  slow-tier.txt stable-core.txt exclude-known.txt bigmem-seed.txt"

MANIFEST_BODY="$(mktemp)"; trap 'rm -f "$MANIFEST_BODY"' EXIT

deploy_one(){ # $1 src (repo-relative)  $2 dest  $3 mode
  local src="$SCRIPTDIR/$1" dest="$2" mode="$3"
  [ -f "$src" ] || { log "MISSING in repo: $1"; rc=1; return; }
  if ! cmp -s "$src" "$dest" 2>/dev/null; then
    install -m "$mode" "$src" "$dest" || { log "install failed: $dest"; rc=1; return; }
    log "updated: $1 -> $dest"
  fi
  sha256sum "$dest" | sed "s|$dest|$1|" >> "$MANIFEST_BODY"
}

for s in $GUEST_SCRIPTS; do deploy_one "$s" "$ROOTFS/$s" 755; done
deploy_one mount.fuse.fuse2fs "$ROOTFS/usr/sbin/mount.fuse.fuse2fs" 755
for l in $LISTS; do deploy_one "$l" "$R/$l" 644; done

# xfstests patches: verify each is applied in the deployed tree.
for p in "$SCRIPTDIR"/patches-xfstests/*.patch; do
  name=$(basename "$p")
  if patch -p1 -R --dry-run --batch -d "$XT" < "$p" >/dev/null 2>&1; then
    sha256sum "$p" | sed "s|$p|patches-xfstests/$name (applied)|" >> "$MANIFEST_BODY"
  elif patch -p1 --dry-run --batch -d "$XT" < "$p" >/dev/null 2>&1; then
    if [ "${APPLY:-0}" = 1 ]; then
      patch -p1 --batch -d "$XT" < "$p" >/dev/null && log "applied: $name" \
        || { log "patch application FAILED: $name"; rc=1; }
      sha256sum "$p" | sed "s|$p|patches-xfstests/$name (applied)|" >> "$MANIFEST_BODY"
    else
      log "NOT applied in $XT: $name (rerun with APPLY=1, or rebuild xfstests)"; rc=1
    fi
  else
    log "patch $name neither applies nor reverses in $XT — tree has drifted, rebuild xfstests"; rc=1
  fi
done

# Rootfs invariants: /bin,/sbin,/lib,/lib64 must be symlinks into usr/
# (a dpkg -x style extraction replaces them with real dirs and quietly
# shadows half the userspace — bit us before).
for d in bin sbin lib lib64; do
  [ -L "$ROOTFS/$d" ] || { log "INVARIANT VIOLATION: $ROOTFS/$d is not a symlink"; rc=1; }
done
[ -x "$ROOTFS/usr/sbin/mount.fuse.fuse2fs" ] || { log "INVARIANT VIOLATION: mount.fuse.fuse2fs not executable"; rc=1; }
[ -x "$ROOTFS/shard-init.sh" ] || { log "INVARIANT VIOLATION: shard-init.sh not deployed"; rc=1; }

# Report unmanaged drift (present on rig, unknown to repo) — informational.
GS_FLAT=" $(echo $GUEST_SCRIPTS) "   # collapse newlines for the word match
for f in "$ROOTFS"/*.sh "$ROOTFS"/qemu-init; do
  b=$(basename "$f")
  case "$GS_FLAT" in *" $b "*) ;; *) log "note: unmanaged guest script on rig: $b";; esac
done

[ $rc -ne 0 ] && fail "deploy incomplete — NOT writing manifest (gate will report last good state)"

GITDESC=$(git -C "$SCRIPTDIR" describe --always --dirty 2>/dev/null || echo unknown)
sort "$MANIFEST_BODY" -o "$MANIFEST_BODY"
HASH=$(sha256sum "$MANIFEST_BODY" | cut -c1-12)
{ echo "$HASH $(date +%Y-%m-%dT%H:%M:%S) repo=$GITDESC"
  cat "$MANIFEST_BODY"
} > "$BASE/.deploy-manifest"
log "manifest: $HASH repo=$GITDESC ($(wc -l < "$MANIFEST_BODY") entries) -> $BASE/.deploy-manifest"
