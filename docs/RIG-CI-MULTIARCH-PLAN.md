# Rig regression protection & multi-arch plan (discussed 2026-07-17)

Context: three filesystems supported (btrfs, xfs, fuse2fs); one afternoon
of fuse bring-up produced five broken sweeps, all rig regressions a cheap
gate would have caught. Decisions below agreed in discussion; none
implemented yet except where noted.

## Regression protection (priority order)
1. **Tri-fs smoke gate = the rig's CI.** Extend dev-check.sh smoke to
   run per-fs: smoke x {btrfs, xfs, fuse}, ~2 min total. Rule: any
   change under rootless-uml/, the rootfs, or xfstests-built must pass
   the gate before any full sweep. Local pre-flight (optionally a git
   pre-push hook) — the rig is hardware-bound, no hosted CI.
2. **deploy.sh with manifest.** Kill the repo-copy-vs-deployed-copy
   divergence (bit us: qemu-init pool support, queue-init fuse branch).
   One script syncs the blessed set, applies patches-xfstests/, verifies
   rootfs invariants (/bin,/sbin,/lib are symlinks — the dpkg -x tar
   clobber class), prints a manifest hash the smoke gate records.
   Long-term: generate the rootfs fully from the repo.
3. **Baselines as committed data.** Per-fs confirmed-failure lists +
   counts in results/ (started: baseline-fuse-confirmed.txt). Every
   sweep diffs against baseline: new failures = regression alarm,
   disappeared = progress to fold in.
4. **Serial on hardware, parallel on calendar.** Full sweeps are
   timing-sensitive and share one host (the interlock exists for a
   reason): nightly rotation script runs tri-fs smoke + one (or all
   three, serially) full sweeps + baseline diff + dated report.
5. **PINS manifest + weekly advance ritual.** One file: kernel SHAs per
   upstream (btrfs for-next, xfs for-next, mainline for fuse), xfstests
   SHA, e2fsprogs/fuse2fs version, rootfs snapshot date. Advance weekly
   on a quiet day: bump, rebuild, gate, sweep, triage delta, commit new
   baselines. Never advance mid-investigation. Keep per-pin kernel
   binaries as named artifacts (formalizes linux.pre-xfs-style backups).
6. **Rig invariant asserts.** In run-queued aggregate: done + claimed +
   queued == total and verdicts ~= tests-run (catches marker stranding
   and silent queue inhalation classes). Sick-lane guard and startup
   interlock already implemented.

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
