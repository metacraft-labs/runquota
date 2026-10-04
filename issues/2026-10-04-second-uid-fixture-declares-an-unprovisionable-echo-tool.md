# Second-UID fixture declares an external tool without Nix provisioning

| Field | Value |
| --- | --- |
| Status | Open; repair authorized by the current stabilization |
| Observed in | `245ae0593b571f65fc262f04084deb37cb8e0494`, Linux ARM Repro CI `37197777507`, job `111423122069` |
| Expectation | `repro.nim` declares Nix provisioning on POSIX; `docs/repository-requirements.md` requires tools from the declared store; `docs/database.md` requires real second-UID admission and persisted attribution |

The complete local debug, optimized and path-provisioned Repro suites pass
at this source. CI's Nix-provisioned test graph fails before any test launches:
`package "echo" requested by uses "echo" does not declare provisioning:
nixPackage metadata`. The preceding build graph succeeds because this tool
belongs to the second-UID test action.

The fixture added by `50e4e26` requires immutable tool paths and correctly
preserves multicall aliases. Its leased child uses external `echo`, which is
available in the local development shell but lacks the selected tool registry's
Nix package metadata. Bash's own `echo` statements are builtins and are a
separate use. The failed job log is retained at
`/tmp/runquota-245-linux-arm-failure.log`.

Fresh product refs and both open and historical provisioning/tool issues were
searched. The Windows archive-policy issue covers a different provisioning
path. This defect belongs to the new POSIX fixture's tool selection.

## Required repair and qualification

Use the existing provisionable `printf` tool for the actual leased executable,
with an explicit `%s\n` format and the same marker argument. Keep immutable
Nix paths, real builder users, the real daemon and CLI lease, every directory
and socket permission check, kernel refusal, spoof rejection and SQLite owner
attribution assertion. The child must still execute as a separate real process;
replacing it with a shell builtin would not meet this contract.

Reproduce the original Nix tool-resolution refusal locally, then execute the
real fixture with Nix provisioning after repair. Compare output bytes with the
former real executable. Repeat complete native debug, optimized and forced
Repro suites, including Nix provisioning, before updating PR 39. Retain the
failed platform result and require a fresh complete matrix before promotion.
