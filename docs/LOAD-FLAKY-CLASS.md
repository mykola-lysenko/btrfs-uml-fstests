# The LOAD-FLAKY class: mechanisms, verdicts, dispositions

Tests that fail under UML sharded load but pass solo (auto-classified by the
supervisor's solo-retry lane). Debugged to mechanism level 2026-07-12.

| test | failure mode | verdict | disposition |
|---|---|---|---|
| generic/044/045/046 | fsync'd files have size but no extents after simulated crash | **0/14 on QEMU/KVM under load** vs ready repro under UML load → UML artifact | excluded-under-load via retry-lane; see ubd hypothesis |
| btrfs/297 | RAID5/6 parity block stale (ff where aa expected) | **0/8 on QEMU/KVM under load** → UML artifact | same |
| btrfs/081 | bash deferred job-notice ("wait_for: No record of process") surfacing at cleanup boundary | shell noise, not fs; per-command redirect cannot catch a deferred notice | patch v1 fixed the deterministic case; residual is rare and absorbed by retry lane |
| generic/208 | helper aio-dio-invalidate-failure prints "invalidation returned -EIO, OK" — an outcome the helper itself accepts — but the golden output lacks the line | upstream test bug | **upstream candidate #6**: accept the helper's own OK outcome |
| generic/604 | mount loses the intended race to util-linux's userspace "already mounted" pre-check (stale mountinfo during slow umount), never reaching the kernel s_umount race the test targets | upstream test robustness | **upstream candidate #7**: retry on the userspace refusal |
| generic/415 | slow fill test near the 900s cap; occasionally times out under load | calibration, no artifact preserved | slim tier + retry lane |

## The ubd write-ordering hypothesis (future arch/um work)

The two fs-level artifacts (lost fsync'd extents post-shutdown; stale parity)
are both WRITE-ORDERING failures, appearing only under UML with host load, and
never on KVM with identical kernels. Hypothesis: arch/um's ubd driver weakens
flush/FUA ordering under host I/O pressure (host-side buffering of the backing
file absorbs barriers that the guest fs assumed durable/ordered), so
crash-simulation (shutdown ioctl) and parity-consistency checks observe states
that real block devices never expose. If true this is an upstream arch/um
issue worth a dedicated barrier-semantics test campaign — parked as future
work; operationally the retry-lane classifier keeps these flakes from
polluting results.
