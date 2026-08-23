# observation-write-path

The per-execution latency the **socket** observation write path adds,
measured against a capture-disabled control (`runquotad --no-write-stats`).

Run it with:

```
just bench-observation-write-path            # full run
just bench-observation-write-path --quick    # short run
```

Results land in `bench-results/runquota-observation-write-path.json`.

## What is measured

Two daemons run at the same time from the same binary — one with capture on
(no flag), one with `--no-write-stats` — and each round times one complete
execution against each, alternating which goes first. The client sends the
same message sequence to both, including the in-flight `LeaseObservation`
report, so the difference is the daemon-side cost of capture and nothing
else.

The headline is the **paired median difference**. Pairing is what makes the
figure survive a machine somebody is using: an unpaired before/after
measurement on a workstation is dominated by whatever else the host was
doing, which M11 measured directly.

The harness refuses to report a number unless the capture arm really did
record one row per execution and the control arm really did write nothing.

## What the number does not decide

M13 is the **fallback** path. The ring (M22) is the fast path and carries
the default-on decision, so an unfavourable figure here is a finding about
the fallback rather than an argument about the default.
