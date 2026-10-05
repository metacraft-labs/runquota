---
title: RunQuota
description: RunQuota is a host-wide lease coordinator. It decides when work may start, so a machine running several builds and test suites at once is not oversubscribed.
order: 1
---
# RunQuota

:::hero title="RunQuota"
:::button href="/getting_started" variant="primary"
Get Started
:::button href="https://github.com/metacraft-labs/runquota" variant="secondary"
GitHub
:::

## Overview

RunQuota is a host-wide lease coordinator. Tools that launch concurrent process trees — build systems, test runners, benchmark harnesses — ask it for a lease before they start a piece of work, and it decides whether that work may start now, must wait, or cannot be admitted at all.

## The problem it solves

Every tool that runs work in parallel picks a width. A build system picks one, a test runner picks another, and an agent session running both picks neither. Each of them is correct on its own and wrong together: the machine ends up running the sum of everybody's idea of "as wide as this host can go", and the result is a host swapping, OOM-killing the one job that mattered, or simply finishing everything later than it would have with less concurrency.

Nobody can fix that locally, because no single tool can see the others. The fix has to be one authority over one machine's resources, and that is what RunQuota is: a single daemon per host, serving every user on it, that admits work against the host's real budget rather than each tool's guess at it.

## The shape of it

- `runquotad`: The lease authority. One per host. It holds the budget, decides admission, and records what actually happened. It never spawns, sandboxes, monitors, or kills anybody's processes — it only says yes, wait, or no.
- `runquota`: The command-line client: inspect the daemon, read the recorded history, and run a command under a lease.
- `observation store`: A durable, append-only record of what every admitted execution actually cost. It turns "how much memory will this need?" from a guess into a measurement.

## Start here

:::cards
:::card title="Getting Started" icon="/assets/img/icon__start.svg" href="/getting_started"
Learn core lease concepts, understand host coordination, and provision a host for daemon operation.
:::card title="Usage Guide" icon="/assets/img/icon__components.svg" href="/usage_guide"
Run the coordinator daemon, acquire leases with the CLI, and inspect observation records.
:::card title="Reference" icon="/assets/img/icon__style.svg" href="/reference"
Comprehensive reference for environment variables, daemon configurations, and troubleshooting guides.
:::

## Popular articles

:::cards variant="compact"
:::card title="Lease Concepts" href="/getting_started/concepts"
Getting Started
:::card title="Provisioning a Host" href="/getting_started/provisioning"
Getting Started
:::card title="Running the Daemon" href="/usage_guide/daemon"
Usage Guide
:::card title="The runquota CLI" href="/usage_guide/cli"
Usage Guide
:::card title="Observation Store" href="/usage_guide/observations"
Usage Guide
:::card title="Troubleshooting" href="/reference/troubleshooting"
Reference
:::

## What RunQuota is not

It is not a sandbox, a supervisor, or a scheduler that runs your work for you. It grants leases; your tool runs its own processes and reports back. It is not a cluster scheduler either — its scope is exactly one machine, deliberately, because that is the scope at which the oversubscription problem exists.
