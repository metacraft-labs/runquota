## TEARDOWN THAT WAITS FOR THE DAEMON'S FILES TO SETTLE.
##
## THE DEFECT THIS EXISTS FOR. `defer: removeDir(root)` is registered before
## the daemon starts, so it runs after `daemon.stop()` -- and `stop()` waits
## for the DAEMON, not for the `sqlite3` children the daemon spawned. SIGTERM
## ends the daemon outright; a child of its observation writer can still be
## finishing a transaction, recreating `-wal` and `-shm` beside a database
## `removeDir` has already walked past. `removeDir` then raises "Directory
## not empty" AFTER the test itself has passed, which reports a fixture's
## timing as the product's failure. It was seen failing once and passing on
## re-runs, which is the signature.
##
## THE WAIT IS ON THE CONDITION, NOT A RETRY OF THE REMOVAL: two consecutive
## identical samples mean nothing is still appearing, which is the thing that
## was actually wrong. It costs one sampling interval on a quiet tree and
## returns as soon as the tree is quiet, so it does not trade a flake for a
## fixed delay.
##
## The bound exists because a wait that can never end is worse than the race:
## past it the removal is attempted anyway, and a directory that really will
## not empty raises exactly as it did before.
##
## WHY IT IS HERE AND NOT IN EACH FILE. It was written twice, verbatim, in
## `t_observation_query_interface` and `t_observation_socket_write_path`, and
## a third file needed it. A fixture helper that is copied is a fixture
## helper that gets fixed in one copy.
##
## THE RULE: a test that starts a REAL `runquotad` over a REAL socket tears
## its scratch root down with this, not with `removeDir`. Several files that
## start a daemon still use a bare `removeDir` and carry the same exposure;
## they are quiet because the race needs a `sqlite3` child outliving the
## daemon by the width of one `walkDirRec`, which is a condition a test does
## not control. Converting one when it is next touched is cheaper than
## diagnosing it once.

import std/os

proc scratchEntryCount*(root: string): int =
  ## How many entries are under ``root`` right now. A fingerprint, not an
  ## inventory: all it has to do is CHANGE when a file appears.
  try:
    for _ in walkDirRec(root, yieldFilter = {pcFile, pcDir, pcLinkToFile,
        pcLinkToDir}):
      result += 1
  except OSError:
    # A directory that cannot be walked cannot be observed settling either;
    # the caller's bounded wait then simply expires and it removes what it
    # can, which is what it would have done before this proc existed.
    discard

proc removeScratchRoot*(root: string) =
  ## Waits for ``root`` to stop changing, then removes it.
  ##
  ## ON WINDOWS A FILE THAT IS STILL OPEN CANNOT BE DELETED, and stopping the
  ## daemon there is `TerminateProcess`: its `sqlite3` children are not
  ## signalled with it and finish the statement they were given, holding the
  ## database open for that long. Nothing about that is visible as the tree
  ## CHANGING, so the settle wait below cannot see it; the removal itself is
  ## the only probe, and a sharing violation is retried within the same
  ## bound. Past it the error is raised exactly as before.
  const
    SettleStepMillis = 25
    SettleBudgetMillis = 2000
  var previous = -1
  var waited = 0
  while waited <= SettleBudgetMillis:
    let current = scratchEntryCount(root)
    if current == previous:
      break
    previous = current
    sleep(SettleStepMillis)
    waited += SettleStepMillis
  when defined(windows):
    var retried = 0
    while true:
      try:
        removeDir(root)
        return
      except OSError:
        if retried >= SettleBudgetMillis:
          raise
        sleep(SettleStepMillis)
        retried += SettleStepMillis
  else:
    removeDir(root)
