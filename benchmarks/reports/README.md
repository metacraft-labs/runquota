# Benchmark Reports

Committed benchmark results. `bench-results/` is gitignored scratch — a run
writes there, a *result* lands here.

A result in this directory must carry, alongside its numbers:

- the **host**: CPU topology, page size, OS version;
- the **build mode of every binary involved**, not just this repository's —
  see `scripts/lib/build_mode.sh` for why a debug measurement is a wrong
  comparison rather than merely a slow one;
- the **subjects** measured and why those;
- the **number of independent invocations** behind each figure;
- the **load that actually arrived**, measured, not assumed. This host runs
  CI runners and is never quiet.

## Results

| File | Milestone | What it establishes |
|---|---|---|
| [`M1-socket-baseline.md`](./M1-socket-baseline.md) | M1 | What RunQuota's unix-socket transport costs a real `repro` build, broken down into admission versus reporting. The baseline M8, M22 and M23 are measured against. |
