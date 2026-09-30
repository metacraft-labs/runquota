# Cancelled scanner fixtures can block the next checkout

| | |
| --- | --- |
| Status | in-progress on `agents` |
| Recorded | 2026-09-29 |
| Observed in | RunQuota `ae38968` |
| Area | `scripts/test_nim_ref_token_scanner.sh` compiler-shadow fixture |

## Observed

macOS lint job `109314731119` in run `36540459597` fails during checkout:

```text
EACCES: permission denied, unlink '/private/var/lib/github-runner-work/mcl-004/runquota/runquota/build/test-work/runquota-ref-scanner.45Vbdy/hostile-project/scripts/compiler/ic/dce.nim'
```

The fixture uses `cp -R` to copy the immutable Nix compiler tree. This preserves
read-only directory modes. Its EXIT trap restores write access, but forced job
cancellation can prevent that trap from running. The exact termination of the
earlier fixture process has not been measured; cancellation is a possible cause,
not an established one. The retained directory blocks both Git cleanup and the
checkout action's fallback deletion before lint can execute.

## Expected

[Repository Requirements](../docs/repository-requirements.md) requires the
scanner regression suite and the native lint/test gates. Scratch fixtures must
not prevent a later job from reaching those gates. The compiler-shadow fixture
is deliberately mutable; the authoritative source and compiler remain in the
immutable Nix store and must keep their existing integrity checks.

## Evidence and repair

Fetched `dev@e9f9011` and `agents@ae38968`, confirmed dev is an ancestor, and
searched open and deleted issues for compiler-shadow, read-only fixture and
checkout permission failures. The Windows retained-DLL issue has a different
cause.

Copy the compiler-shadow fixture with GNU coreutils `--no-preserve=mode`, so
each copied directory is removable from the moment it is created. The gate
already pins GNU coreutils. Retain the EXIT cleanup and every scanner assertion.
Repair permissions only on the identified retained scratch tree, then rerun the
failed native job. The new copy must still pass the full static-helper gate.
