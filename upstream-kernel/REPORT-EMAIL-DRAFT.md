# Draft: report + patch for linux-btrfs

**To:** linux-btrfs@vger.kernel.org
**Cc:** hch@lst.de, dsterba@suse.com, clm@fb.com, akpm@linux-foundation.org
**Subject:** [PATCH] btrfs: handle 3-device RAID6 without calling the raid6 library

(The patch file `0001-btrfs-handle-3-device-RAID6-without-calling-the-raid.patch`
is the actual submission; its commit message is self-contained. The text below
is optional cover-letter material if sent as a reply to a report thread, or
can be trimmed into the `---` section of the patch.)

---

Since the lib/raid6 -> lib/raid/raid6 refactor in 7.2-rc1, fstests
btrfs/297 fails its dmesg check when SCRATCH_DEV_POOL has 3 devices:

    WARNING: lib/raid/raid6/algos.c:48 at raid6_gen_syndrome+0x4d/0x60
    Workqueue: btrfs-rmw rmw_rbio_work

Commit 2790045a62eb ("raid6: warn when using less than four devices")
added the assertion deliberately and its commit message already calls
out btrfs as the one caller that allows 3 devices, suggesting btrfs
handle the degenerate case as mirroring. This patch does exactly that:
for real_stripes < RAID6_MIN_DISKS both P and Q are memcpy()s of the
single data stripe, matching the existing inline RAID5 fallback in the
same functions.

Note the failure is easy to miss in CI: the assertion is WARN_ON_ONCE,
so only the first 3-device raid6 test of each boot fails and every
later one passes silently.

Verified on 7.2.0-rc1 (x86-64/KVM and UML):
- unpatched: btrfs/297 first run fails _check_dmesg with the trace above
- patched: btrfs/297 x3 passes, no warnings; full fstests raid group
  regression-clean

## Send procedure (when ready — see docs/UPSTREAM-PREP-PLAN.md first)

    cd ~/uml-smoke/linux-mainline   # or any kernel git checkout for get_maintainer
    git send-email \
      --to=linux-btrfs@vger.kernel.org \
      --cc=hch@lst.de --cc=dsterba@suse.com \
      /home/prozak/sources/btrfs-uml-fstests/upstream-kernel/0001-*.patch

## Open questions to resolve before sending

1. Should btrfs *also* stop allowing new 3-device raid6 (devs_min 3 -> 4)?
   That's a separate policy question for the maintainers — mention it in the
   cover text but don't bundle it; changing devs_min affects existing
   filesystems (mount, balance, device remove).
2. hch's message says "switch to transparently use three-way mirroring" —
   our memcpy approach IS that, at the parity-generation level. A deeper
   rework (routing 3-dev raid6 through the raid1c3 code path entirely) would
   be much more invasive; flag it as an alternative if maintainers prefer.
3. Check whether a btrfs-side fix appeared upstream after 2026-07-15 before
   sending (lore was Anubis-blocked from this environment; re-check manually:
   https://lore.kernel.org/linux-btrfs/?q=RAID6_MIN_DISKS).
