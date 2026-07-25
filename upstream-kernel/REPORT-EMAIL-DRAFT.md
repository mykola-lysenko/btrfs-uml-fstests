# Draft: report + patch for linux-btrfs — SUPERSEDED, never sent

The 3-device RAID6 `RAID6_MIN_DISKS` WARN this draft addressed is fixed
architecturally upstream by Qu Wenruo's "btrfs: disguise single-data-RAID56
as RAID1/RAID1C3" series (merged in btrfs misc-next as of 2026-07-20;
<https://lwn.net/Articles/1074081/>). The patch file was removed from this
repo; full analysis and the superseded fix are preserved in
`docs/RAID6-3DEV-WARN-FINDING.md`.

Mainline 7.2 still carries the WARN until the series propagates; if a
stable-targeted minimal fix ever becomes relevant, that's a question for
Qu/David on linux-btrfs, not a reason to resurrect this draft.
