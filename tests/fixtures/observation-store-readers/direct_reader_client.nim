## FIXTURE, NOT SHIPPED CODE. The violation the reader boundary exists to
## catch: client-side code that opens the observation database itself
## instead of asking ``runquotad``.
##
## It is deliberately plausible. It compiles, it works, it is faster than a
## round trip, and it is exactly what somebody writes on the afternoon they
## discover the store is "just a SQLite file". What it also does is read a
## schema RunQuota owns, past every scoping rule the daemon applies: no
## peer credentials, so no uid scoping; no profile qualification, so a
## laptop's rows and a builder's rows pool freely.
##
## ``t_observation_store_reader_boundary`` scans this file and REQUIRES it
## to be flagged. If it ever stops being flagged, the scanner has gone
## blind and the gate it guards has stopped guarding anything.

import runquota_observation_store

proc slowestExecutions*(databasePath: string): seq[ExecutionRow] =
  let store = openObservationStore(databasePath)
  if not store.captureEnabled:
    return @[]
  store.readExecutions()
