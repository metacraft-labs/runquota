# Reprobuild test collection is missing

Status: open. Observed at RunQuota `74627a3` in Linux ARM64 job `109092119183`.
The shipping applications build, then `repro test` refuses with "unknown build
target: test". The recipe declares a development-shell task with that name,
which does not register a build-graph collection.

The unified release plan and CI workflow standards require the complete test
catalog through Reprobuild as well as the native entrypoint. Register separate
compile and execution edges for the existing deterministic catalog, preserving
sorted discovery, duplicate-name rejection, application dependencies and the
600-second execution bound. Expose `test` and `test-builds`. Keep the existing
static-helper authority gate in the complete `just test` cross-check.

Refreshed origin/dev `f4f0f93` (already an ancestor) and searched open/deleted
issues for missing test collections before recording. Native Linux ARM64 and
macOS catalogs both pass all 96 programs at `74627a3`; this is a graph gap.
