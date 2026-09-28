# macOS CI cannot find the Nix static-helper gate

| | |
|---|---|
| Status | in progress — preserve the CI development shell with a Nix profile |
| Observed in | RunQuota `d6d65ad` |
| Recorded | 2026-09-28 |
| Area | Nix development shell and static-helper validation |

## Observed

The macOS CI job runs `nix develop --command just test`, builds the
`runquota-static-helper-gate` derivation, and passes all 95 test programs.
The final helper check reports `runquota static helper gate: NOT RUN` because
`command -v runquota-static-helper-gate` fails. The log does not distinguish
a changed PATH from a missing or non-executable store file.

## Expected

[Repository requirements](../docs/repository-requirements.md) requires the
static-helper checks under the pinned Nix authority. `flake.nix` declares its
wrapper in `devShells.default.packages`; entering that shell must provide it.
Keep the fail-closed gate while diagnosing the missing executable.

## Evidence

[macOS job 108970146689](https://github.com/metacraft-labs/runquota/actions/runs/36434897045/job/108970146689)
at `d6d65ad` builds the wrapper at 14:45:48 UTC and cannot resolve it at
14:57:42 UTC. At the same commit the full Linux suite and local macOS
`nix develop --no-write-lock-file --command just test` pass all 95 programs
and the helper checks. macOS CI lint and Nix package build also pass.

Synced `origin/dev` and `origin/agents`; searched current issues and issue
history for the static-helper gate, PATH and Nix shell before filing.

## Diagnosis and repair

[Diagnostic job 108994956361](https://github.com/metacraft-labs/metacraft-github-actions/actions/runs/36442100739/job/108994956361)
at `d6d65ad` runs the helper successfully at 15:18 UTC, then passes all 95
test programs. At 15:29 UTC the wrapper's store path no longer exists;
the outer shell's PATH is unchanged. This establishes deletion during the
suite, rather than a failed shell activation. The deleting process was not
observed; Nix garbage collection is the likely cause.

Root CI lint and test environments with `nix develop --profile` under the
job's `RUNNER_TEMP`. The profile retains the wrapper and its complete source
and compiler closure until runner cleanup removes that job's temporary
directory. Keep the existing static-helper gate and its authority checks.
Validate the rooted environment with the complete native macOS suite.
