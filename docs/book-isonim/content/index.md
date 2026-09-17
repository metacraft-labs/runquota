---
title: RunQuota
description: RunQuota is a host-wide lease coordinator. It decides when work may start, so a machine running several builds and test suites at once is not oversubscribed.
order: 1
---
# RunQuota

RunQuota is a **host-wide lease coordinator**. Tools that launch concurrent
process trees — build systems, test runners, benchmark harnesses — ask it for a
**lease** before they start a piece of work, and it decides whether that work
may start now, must wait, or cannot be admitted at all.

## The problem it solves

Every tool that runs work in parallel picks a width. A build system picks one,
a test runner picks another, and an agent session running both picks neither.
Each of them is correct on its own and wrong together: the machine ends up
running the sum of everybody's idea of "as wide as this host can go", and the
result is a host swapping, OOM-killing the one job that mattered, or simply
finishing everything later than it would have with less concurrency.

Nobody can fix that locally, because no single tool can see the others. The
fix has to be **one authority over one machine's resources**, and that is what
RunQuota is: a single daemon per host, serving every user on it, that admits
work against the host's real budget rather than each tool's guess at it.

## The shape of it

- **`runquotad`** is the lease authority. One per host. It holds the budget,
  decides admission, and records what actually happened. It never spawns,
  sandboxes, monitors or kills anybody's processes — it only says yes, wait,
  or no.
- **`runquota`** is the command-line client: inspect the daemon, read the
  recorded history, and run a command under a lease.
- The **observation store** is a durable, append-only record of what every
  admitted execution actually cost. It is what turns "how much memory will
  this need?" from a guess into a measurement.

## Where to start

- [What a lease is](/getting_started/concepts) — the vocabulary the rest of
  this book uses.
- [Provisioning a host](/getting_started/provisioning) — the one install step
  RunQuota will not do for you, and the refusal you get if you skip it.
- [Running the daemon](/usage_guide/daemon) — flags, startup, shutdown.
- [The `runquota` CLI](/usage_guide/cli) — every subcommand.

## What RunQuota is not

It is not a sandbox, a supervisor, or a scheduler that runs your work for you.
It grants leases; your tool runs its own processes and reports back. It is not
a cluster scheduler either — its scope is exactly one machine, deliberately,
because that is the scope at which the oversubscription problem exists.
