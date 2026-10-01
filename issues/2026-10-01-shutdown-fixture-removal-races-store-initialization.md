# Shutdown fixture removal races store initialization

Status: open. Linux diagnostic
[`5e6cb15`, job 110499005762](https://github.com/metacraft-labs/runquota/actions/runs/36900752734/job/110499005762)
executes identical daemon and fixture binaries natively and under monitoring.
The first pair succeeds; in the second monitored execution, the socket-only
case exits zero, then `removeDir(root)` in the scratch-tree case throws
`Directory not empty` for its `state` directory. Both native executions pass.
This is not the SIGSEGV recorded in the neighboring shutdown issue.

[`docs/database.md`, When the endpoint appears](../docs/database.md#when-the-endpoint-appears)
requires serving leases while the store opens. Consequently a served Hello
proves readiness but does not prevent the opener from creating files during the
fixture's recursive removal. The fixture must complete that real removal before
asserting that all paths are gone and sending SIGTERM.

Retry only ENOTEMPTY within a bounded setup budget; unexpected errors remain
fatal. Preserve the completed-Hello precondition, both absence assertions, the
original shutdown deadline and exit-zero requirement. Retain every diagnostic
failure and continue repetitions until the original crash recurs or the bounded
comparison finishes.

Fetched `agents` / `dev` at `0167c4b` / `0389129` and searched current and
archived scratch-directory, removal and shutdown records before filing.
Evidence: `/tmp/runquota-5e6-linux-daemon-controls`.
