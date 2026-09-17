---
title: Getting Started
order: 0
---
# Getting started

Three steps, in this order:

1. **[Provision the host](/getting_started/provisioning).** RunQuota needs two
   directories that the install step creates and the daemon deliberately will
   not. This is the single most common first-run stumble, and it has two
   different symptoms depending on which directory is missing.
2. **Start `runquotad`.** One daemon per host. See
   [Running the daemon](/usage_guide/daemon).
3. **Point a client at it.** Either your build tool (which speaks the protocol
   directly) or the [`runquota` CLI](/usage_guide/cli).

Before any of that, it is worth reading
[Concepts](/getting_started/concepts) — RunQuota's error messages, JSON output
and CLI flags all speak in terms of leases, sessions, resource vectors and
estimates, and none of those mean quite what you would guess.

## A one-minute check that it works

With the host provisioned and the daemon running:

```console
$ runquota status
sessions: 0
leases: 0
...
```

and a command run under a lease:

```console
$ runquota acquire --cpu 2000 --mem 512mib -- make -j2
```

If there is no daemon, that second command **still runs your program**.
RunQuota treats a missing daemon as a degradation, not an error: the work
happens, it is simply not coordinated and not recorded. See
[Standalone mode](/getting_started/concepts#standalone-mode) for why, and
`RUNQUOTA_REPORT_STANDALONE` in
[Environment variables](/reference/environment_variables) for how to make the
degradation visible when you would rather know.
