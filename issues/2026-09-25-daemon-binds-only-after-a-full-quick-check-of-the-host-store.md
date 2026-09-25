# runquotad binds its endpoint only after a full `quick_check` of the host-wide observation store

| | |
|---|---|
| Status | open |
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
