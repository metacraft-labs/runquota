## A declaration that waits out SQLite's busy timeout leaves the store open.
##
## REGRESSION TEST FOR reprobuild-pm
## ``issues/2026-11-20-runquota-declaration-busy-timeout-behind-a-prune-degrades-the-store.md``.
##
## THE PROPERTY. OS-4 degrades a store that cannot be WRITTEN. A
## ``begin immediate`` that is refused because another connection held the
## write lock for longer than the 5 s busy timeout -- a retention delete over
## a large store -- is a statement that could not run NOW, not a store that
## cannot be written. It used to publish ``ssUnwritable``, which turns capture
## off for the whole host on the strength of one declaration. It must answer
## ``unavailable`` (retryable) and leave the store ``ssOpen``, and the same
## declaration must succeed once the lock is free.
##
## HOW THE LOCK IS HELD. A real second connection, on a thread of its own,
## runs ``begin immediate`` followed by a recursive-CTE count long enough to
## outlast the busy timeout, then commits. No mock: real SQLite, real file,
## real lock. The test checks the holder really held the lock beyond the
## timeout (the declaration took at least the busy timeout to fail), so it
## cannot pass vacuously on a fast machine; the holder's row count is sized
## in ``holdRows`` with a wide margin, and a machine fast enough to finish it
## early fails the vacuity check rather than passing it.

import std/[atomics, os, strutils, tempfiles, times, unittest]

import runquota_observation_store

const
  holdRows = 30_000_000
    ## Rows the holder's CTE counts: about 14 s of work on the home-pc
    ## (~2.2 M rows/s in a debug build), well past the 5 s timeout.
  declaredExtension = "busytimeout_new"
  declaredOwner = "runquota-busy-timeout"

var
  holderLocked: Atomic[bool]
  holderDone: Atomic[bool]

proc extensionDdl(extensionId: string): string =
  "create table " & extensionTableName(extensionId) & " (\n" &
  "  host_id text not null,\n" &
  "  execution_id text not null,\n" &
  "  note text not null,\n" &
  "  primary key (host_id, execution_id),\n" &
  "  foreign key (host_id, execution_id)\n" &
  "    references executions(host_id, execution_id)\n);"

proc hold(path: string) {.thread.} =
  {.cast(gcsafe).}:
    holderLocked.store(true)
    discard runSqlite(path, "begin immediate;\n" &
      "with recursive c(x) as (select 1 union all select x + 1 from c " &
      "where x < " & $holdRows & ") select count(*) from c;\n" &
      "commit;\n")
    holderDone.store(true)

suite "declare_extension_busy_timeout":
  test "a declaration that outwaits the write lock is unavailable, not a degrade":
    let dir = createTempDir("rq-busy-", "")
    defer:
      closePooledConnections()
      removeDir(dir)
    let path = dir / "observations.sqlite3"
    let store = openObservationStore(path)
    doAssert store.captureEnabled, store.report
    holderLocked.store(false)
    holderDone.store(false)
    var holder: Thread[string]
    createThread(holder, hold, path)
    while not holderLocked.load(): sleep(1)
    sleep(300)   # let `begin immediate` take the lock

    let began = epochTime()
    let outcome = store.declareExtension(ExtensionDeclaration(
      extensionId: declaredExtension, owner: declaredOwner,
      schemaVersion: 1, migrations: @[extensionDdl(declaredExtension)]))
    let waited = epochTime() - began
    let doneWhenAnswered = holderDone.load()
    let statusAfter = store.status
    let errorAfter = store.lastError
    # The holder is joined: its CTE is sized to end in bounded time.
    joinThread(holder)

    check waited >= 4.5
    check not doneWhenAnswered   # the lock really outlasted the declaration
    check "locked" in errorAfter
    check outcome == eoUnavailable
    check statusAfter == ssOpen
    check store.captureEnabled
    # The store is still usable, and the declaration succeeds when retried.
    check store.declareExtension(ExtensionDeclaration(
      extensionId: declaredExtension, owner: declaredOwner,
      schemaVersion: 1, migrations: @[extensionDdl(declaredExtension)])) ==
      eoCreated
