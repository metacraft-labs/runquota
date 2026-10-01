# Linux ARM64 CI crashes while compiling the Reprobuild interface

| | |
|---|---|
| Status | open; attribution pending |
| Recorded | 2026-10-01 |
| Observed in | RunQuota CI at `020e6953791355133425a0547e3c0291205eb38c` |
| Area | `.github/workflows/ci-reprobuild.yml`, Linux ARM64 source bootstrap |

## Observed

[Job 110454460691](https://github.com/metacraft-labs/runquota/actions/runs/36887279486/job/110454460691)
finishes development-environment setup, then fails before compiling RunQuota.
Reprobuild's interface extraction invokes `/usr/bin/aarch64-linux-gnu-gcc-13`
on generated `@prepro_dsl_stdlib@spackages@slibtiff.nim.c` and reports:

```text
Segmentation fault (core dumped)
Error: execution of an external program failed
```

The CI consumer pins Reprobuild `c14b1e618d7c4b64476d89792e80b8e8f10b8a52`
and the Linux bootstrap monitor `3df08c24ee91900b950ed20a3827923d213f2a9c`.
Its compiler is the Nix `nim-fork-2.3.1-codetracer` source-bootstrap compiler.
The subsequent product tests never start. The failure collector uploads no
artifact because interface extraction fails before its action-log paths exist.
Linux x64's Reprobuild test step passes at the same RunQuota commit.

## Expected

[Shared development environment CI, section 4](../../metacraft-dev-guidelines/policies/ci-shared-dev-env.md)
requires the additive Reprobuild lane to exercise the same product gates.
The current Linux ARM64 lane must reach those gates. The initial release's
Linux ARM64 payload deferral does not disable this development test lane.

## Investigation

The log does not establish whether GCC, the enclosing monitor, or another
bootstrap dependency caused the crash. This record describes the consumer CI
failure; it is not evidence of a defect in current Reprobuild or io-mon sources.
Retain the generated source and failed compiler invocation on a repeat, then
compare the identical compile with controlled monitor injection if it repeats.
A qualified newer monitor can be compared as a separate control; a green run
with changed inputs alone does not prove the original cause.

## Search

Fetched RunQuota `agents` and `dev` before recording; their tips were `020e695`
and `0389129`. Searched current documentation and open/deleted issue history
for segmentation faults, compiler crashes and libtiff. No matching record was
found. Local log: `/tmp/runquota-020-linux-arm64-repro-promotion.log`.
