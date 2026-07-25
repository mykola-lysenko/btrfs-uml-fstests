# Rig regression protection & multi-arch plan (discussed 2026-07-17)

Context: three filesystems supported (btrfs, xfs, fuse2fs); one afternoon
of fuse bring-up produced five broken sweeps, all rig regressions a cheap
gate would have caught. Decisions below agreed in discussion; none
implemented yet except where noted.

## Regression protection (priority order)
1. **Tri-fs smoke gate = the rig's CI.** DONE 2026-07-18 (dev-check.sh
   smoke stage; per-fs lists from gen-smoke-list.sh; strict-notrun;
   validated by sabotage tests — which caught a latent dev-check bug:
   the old '^FAILURES:' grep never matched run-supervised output, so
   failures never failed the pipeline). Extend dev-check.sh smoke to
   run per-fs: smoke x {btrfs, xfs, fuse}, ~2 min total. Rule: any
   change under rootless-uml/, the rootfs, or xfstests-built must pass
   the gate before any full sweep. Local pre-flight (optionally a git
   pre-push hook) — the rig is hardware-bound, no hosted CI.
2. **deploy.sh with manifest.** DONE 2026-07-18 (verifies patches
   applied in xfstests-built — caught fuse2fs patch with absolute-path
   headers that -p1 rebuilds would have dropped; heals missing files;
   refuses manifest on invariant violation). Kill the repo-copy-vs-deployed-copy
   divergence (bit us: qemu-init pool support, queue-init fuse branch).
   One script syncs the blessed set, applies patches-xfstests/, verifies
   rootfs invariants (/bin,/sbin,/lib are symlinks — the dpkg -x tar
   clobber class), prints a manifest hash the smoke gate records.
   Long-term: generate the rootfs fully from the repo.
3. **Baselines as committed data.** DONE 2026-07-24 (branch
   ci-baselines): results/baseline-{btrfs,xfs,fuse}-confirmed.txt +
   rootless-uml/baseline-diff.sh; dev-check quick/full gate on NEW
   failures only (smoke/targeted stay strict). First run immediately
   paid off: all 12 btrfs residuals now pass (rootfs/tooling fixes from
   the xfs/fuse bring-up) — btrfs baseline emptied; xfs baseline is
   provisional until the dm-sysfs cluster fix, then re-baseline.
   Every sweep diffs against baseline: new failures = regression alarm,
   disappeared = progress to fold in.
4. **Serial on hardware, parallel on calendar.** Full sweeps are
   timing-sensitive and share one host (the interlock exists for a
   reason): nightly rotation script runs tri-fs smoke + one (or all
   three, serially) full sweeps + baseline diff + dated report.
5. **PINS manifest + weekly advance ritual.** DONE 2026-07-24 (branch
   ci-pins): rootless-uml/PINS (shell-sourceable: kernel SHAs for the
   tri-fs sweep kernel + btrfs-tip A/B kernel, xfstests SHA, e2fsprogs/
   btrfs-progs versions, rootfs snapshot date) + pins-advance.sh
   (check = report moved branches; advance = resolve tip, build BY SHA
   via build-uml-kernel.sh, rewrite PINS, print ritual checklist —
   sweeps/triage/fold stay human). Grows pins per upstream (xfs
   for-next, mainline-for-fuse) when those kernels exist. Advance weekly
   on a quiet day; never mid-investigation. Per-pin kernel binaries stay
   as named artifacts (linux-<NAME>/). PINS is also the intended cache
   key for the hosted UML smoke lane.
6. **Rig invariant asserts.** In run-queued aggregate: done + claimed +
   queued == total and verdicts ~= tests-run (catches marker stranding
   and silent queue inhalation classes). Sick-lane guard and startup
   interlock already implemented.
7. **Per-fs kernel pins (agreed 2026-07-24).** DONE 2026-07-24 (branch
   ci-perfs-pins): KERNEL_BTRFS = kdave/btrfs-devel for-next,
   KERNEL_XFS = xfs-linux.git for-next (kernel.org direct — cgit
   *snapshots* time out but shallow git fetch by SHA works, ~280M;
   build-uml-kernel.sh grew a git-URL source mode), KERNEL_FUSE =
   torvalds/linux master. build-uml-kernel.sh FLAVOR profiles
   (btrfs|xfs|fuse|trifs; xfs profile mirrors for-next-0710 incl.
   XFS_DEBUG + online scrub/repair; TMPFS_XATTR/POSIX_ACL folded into
   the common base per the generic/270 triage). dev-check resolves each
   fs's kernel from PINS (explicit KERNEL= still overrides everything);
   pins-advance handles URL pins via ls-remote and builds with the
   pin's flavor. Smoke gate green per-fs on the new pins (3x20/20).
   PENDING: baseline re-confirmation full sweeps for xfs and fuse on
   their new pins — until then treat NEW failures there as un-triaged,
   not regressions (caveat noted in PINS).

Sequencing: 1+2 first (one evening, kills the dominant regression
source), 3 nearly free, 5 is an hour of bookkeeping, 4 last.

## Other architectures (ARM)
Blocker fact: UML is x86-only in mainline (arm64 UML = unmerged RFC),
so the cheap lane doesn't port; everything else (queue protocol, load
lever, triage discipline, rootless design) is arch-agnostic.

- **Tier 1 — TCG on the current host (zero hardware).**
  qemu-system-aarch64 -M virt without KVM: 10-20x slow, fine for a
  smoke ring + targeted crosschecks. Port = cross-compiled arm64 kernel
  + arm64 rootfs image (fetch arm64 debs from the pool, mkfs.ext4 -d;
  qemu-init is plain bash). Strategic payoff: **page size** — arm64
  4K/16K/64K kernels; 64K-page filesystems are a chronically under-
  tested bug-rich surface x86 cannot express. First target: 64K-page
  smoke ring (CONFIG_ARM64_64K_PAGES).
- **Tier 2 — real ARM host with KVM** (Ampere free tier / Graviton /
  Mac mini): near-native, mass-parallel model returns. One real
  engineering item: queue transport — hostfs is a UML-ism; QEMU guests
  use 9p (-virtfs + mount -t 9p), near drop-in for the atomic-rename
  claim protocol. Side effect: decouples the rig from UML entirely.
  Times/RSS DBs re-measured per arch (add arch suffix, same pattern as
  per-fs DBs).
- **Tier 3 — matrix discipline.** Baselines and PINS grow an arch (and
  page-size) dimension. Epistemology generalizes: "nothing claimed from
  UML alone" -> "nothing claimed from emulation alone"; TCG = triage
  tier, ARM-KVM = confirmation tier.

Sequencing: do NOT start ARM before the CI foundation above exists
(second arch on a hand-deployed rig doubles the regression surface).
Then Tier 1 (~two evenings), Tier 2 when a finding or idle hardware
justifies it.
