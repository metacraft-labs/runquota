# runquotad binds its endpoint only after a full `quick_check` of the host-wide observation store

| | |
|---|---|
| Status | fixed on branch `fix/listen-before-store-check` (awaiting merge to `dev`) |
| Recorded | 2026-09-25 |
| Observed in | runquota @ b561f93 (the revision reprobuild `dev` pins); the code is unchanged at `dev` 24654b5 |
| Area | `libs/runquota_observation_store` (`openObservationStore`, `integrityDetail`); `libs/runquota_daemon` (daemon construction) |

This is the first file in `runquota/issues/`, so the archive search had nothing
to search; `git log --all -- 'issues/*'` returned nothing.

## Observed

`runquotad` constructs its observation store (`openObservationStore`) before
it binds the socket, and `openObservationStore` runs `integrityDetail` -- a
`pragma quick_check` through the `sqlite3` CLI -- over the whole existing
store. With the default store (`/var/lib/runquota/observations.sqlite3`, 287 MB
on the measuring host, shared by every daemon on the machine) that check is
what the daemon spends its startup on. Time from spawn to the socket existing,
same binary, same arguments (`--socket <dir>/runquota.sock --cpu-milli 16000
--memory-bytes 17179869184`):

| `sqlite3` on PATH | flag | spawn → socket |
|---|---|---|
| no (capture degrades to "tool not on PATH") | -- | 42–194 ms |
| yes | -- | 3375, 4421, 4817, 5202, 5929, 8952, 9993 ms |
| yes | `--no-write-stats` | 59, 95 ms |

`strace -f -tt` of one slow start: the first `sqlite3 -batch -noheader -bail
/var/lib/runquota/observations.sqlite3` child ran from 15:38:08.590 to
15:38:23.524 (15 s); `bind()` followed at 15:38:23.802. The check alone,
run by hand against the same file: `pragma quick_check` -> `ok` in 148341 ms
cold, 2723 ms warm.

The listening line is only printed after all of this, so to a caller the
daemon is simply absent for that long. When a store was contended, startup
also printed `write failed (Runtime error near line 4: database is locked
(5)); capture disabled`.

## Expected

Not specified. `docs/database.md` ("Corruption handling") says corruption is
"detected at open with `pragma quick_check`" and that "the store degrades to
no capture and the daemon keeps serving leases" -- which makes the store
secondary to lease service -- but it says nothing about WHEN the endpoint
becomes available relative to that check. Proposed: the endpoint binds and
leases are served without waiting on the store's open-time integrity check;
capture starts once the store is verified (or degrades, as today, if it is
not).

## Evidence

- Timing: a shell loop spawning the daemon and polling for the socket every
  10 ms, with and without `sqlite3`'s directory on PATH and with
  `--no-write-stats`. The reprobuild dev shell puts `sqlite3` on PATH
  (`pkgs.sqlite`), which is why the slow case is the one every reprobuild
  test and developer build meets.
- `strace -f -tt -e trace=execve,bind,wait4` of `runquotad` under the
  reprobuild dev shell (the timestamps above).
- The consequence downstream: reprobuild test binaries that spawn a private
  `runquotad` and poll 200 x 25 ms for its socket failed with
  `runquotad socket did not appear` (e.g.
  `t_integration_scheduler_dependency_gathering_policies`,
  `t_e2e_m51_dsl_stdlib_file_ops`). reprobuild's tests now pass
  `--no-write-stats` to the daemons they spawn -- they never read the store,
  and writing fixture builds into the host-wide store was a leak of its own --
  but a daemon started for real work still pays this on every start.

## Suggested direction

Either bind first and open the store on the drain thread (leases are served
with capture pending; the listening line would then have to report capture
as "verifying" and a later line the verdict, which changes the fixed
three-line startup contract `docs/database.md` describes), or bound the
open-time check (`quick_check(N)`, or skip it when the file's size and mtime
match the last verified pair recorded beside it) and keep the current order.
The first removes the latency; the second keeps the startup contract but
still pays something proportional to the store.

## Related

- `docs/database.md`, "Corruption handling" and "What exists today".
- reprobuild: the private-daemon helpers in its e2e/integration tests (the
  `ensureRunQuotaDaemon` copies) and `repro_core/paths.runquotaEndpointPath`.

## Resolution

Took the first suggested direction, and without changing the startup
contract.

- **Root cause.** `serve` (`libs/runquota_daemon`) called `initDaemon`, whose
  object constructor called `openObservationStore(...)` -- and with it
  `integrityDetail`'s whole-file `pragma quick_check` -- before
  `bindEndpoint`.
- **Change.** `serve` now builds the daemon with `initDaemon(config,
  deferCapture = true)`, which holds a `pendingObservationStore` (new status
  `ssVerifying`, capture off, file untouched); binds; prints and flushes the
  listening line; starts the worker pool (and reports `SERVICE_RUNNING` on
  Windows); and only then starts `captureOpenerMain`, a thread that runs
  `openCapture` (the old store/identity/profile/writer block of `initDaemon`,
  unchanged, lifted out) WITHOUT the daemon lock, installs the result under
  it with `installCapture`, and prints the second and third startup lines.
  `initDaemon(config)` with the default still opens synchronously.
- **What the spec required, and what was kept.** `docs/database.md`,
  "Corruption handling" (OS-4): a failing store "degrades to no capture and
  the daemon keeps serving leases" -- so leases never depended on the check,
  and are now served during it. The check itself still runs in full on every
  start, and nothing is written to or read from the store before it passes:
  every store operation refuses a `verifying` store as it refuses a degraded
  one. Sessions opened in that window are served and not recorded.
- **Startup output.** Still exactly three lines, same order, same content;
  only the first now appears before the check. `runquota inspect
  observations` gains `store_status` (`verifying`, `open`, or a degradation).
- **The opener thread outlives what it allocated.** Under ORC a chunk freed
  by another thread dereferences its allocating thread's state, which dies
  with that thread (`writer.nim`'s header). The opener allocates state that
  lives as long as the daemon, so it parks after installing the store and
  `serve` joins it only after the writer and the rest are torn down.
- **A writer ordering race this exposed, fixed with it.** With the new
  startup timing, `t_stats_table_publication` failed 4 of 8 runs (0 of 8 on
  `dev`) with `executions.owner_uid names no users row`: the `users` upsert
  and the execution were taken by two concurrent drains (the writer thread
  and the aggregate publisher's flush), and the later-taken batch committed
  first. `drainOnce` now holds a `drainLock` from take to settle, so batches
  commit in the order they were taken; enqueues never take it. 10 of 10
  runs passed afterwards. Why the new timing made the race likelier was not
  established; the race itself predates this change.
- **Documented** in `docs/database.md`, "When the endpoint appears",
  including the two consequences: the owner ledger is seeded when the store
  is installed, and a shutdown during verification waits for the check.
- **Regression test.**
  `tests/integration/t_endpoint_serves_before_store_verification.nim` holds
  a real `BEGIN EXCLUSIVE` on a real rollback-journal store so the daemon's
  `quick_check` waits on SQLite's busy handler. On `dev` 3b1de0f the daemon
  was not reachable for the whole 3044 ms the lock was held; with the fix a
  Hello is answered 56-520 ms after spawn (1494 ms once, at a load average
  of 300) while the lock is still held, a lease
  is granted, `store_status` is `verifying`, the session taken in that
  window is absent from the store, and a session taken after the verdict is
  recorded.
