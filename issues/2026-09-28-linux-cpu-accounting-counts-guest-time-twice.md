# Linux host CPU accounting counts guest time twice

- Status: open
- Observed in: RunQuota `939c38a` (unchanged from `e9e487a`)

## Observed

`readHostLoad` sums every field of the aggregate /proc/stat CPU line. Linux
already includes guest in user and guest_nice in nice, so VM workloads count
twice. At e9e487a, high-mem-server CI measured total CPU time at 1.11–1.14 times
wall time multiplied by its 32 logical cores. The parser defect is confirmed;
its exact contribution to that live measurement awaits a native rerun.

## Expected and repair

The RunQuota Observation Store M11 host-wide counter contract requires real
host CPU time. The kernel's
[account_guest_time](https://github.com/torvalds/linux/blob/master/kernel/sched/cputime.c)
adds guest execution to both user/nice and the separate guest counter.
Sum only user, nice, system, idle, iowait, irq, softirq and steal. Test the
byte-format parser with nonzero guest counters and retain live host checks.

Refreshed origin/dev (`f4f0f93`) and agents (`939c38a`), then searched open
issues and deleted issue history for guest CPU accounting before recording.
