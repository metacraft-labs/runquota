## The capacity ledger and its renderings, as pure functions of the events
## fed to them and the clock passed in: what a finish adds, when a session
## group drops out, how many idle groups are kept, and how names that are
## not plain text are labelled.
##
## WHAT IS GUARDED, and the mutation each check fails under:
##
## * A finish without totals adds no CPU and is counted apart. Mutation:
##   count it as a finish with zero CPU (`finishedWithTotals`), and the
##   split check fails.
## * A group drops out of the figures after an hour without activity,
##   unless it is working. Mutations: never treat a group as idle (it is
##   still there after the hour), or ignore whether it is working (a group
##   holding a lease for over an hour disappears).
## * At most `MaxRetainedIdleGroups` idle groups are kept, the most recently
##   active ones. Mutation: drop the cap, and 1100 groups stay.
## * A name that is not UTF-8 gets a `group_hex` label, so two such names
##   stay two series. Mutation: label with the replaced name only, and the
##   two series carry the same labels.
##
## The rendering is checked against Prometheus's own parser in
## `tests/integration/t_capacity_export`; here only what the ledger keeps.
## No mocks: the module has no I/O but the text file writer, which the
## integration test drives.

import std/[sets, strutils, tables, unittest]

import runquota_core/cpu_profile
import runquota_daemon/capacity_metrics

const Hour = GroupIdleDropMillis

proc totals(micros: uint64): FinishTotals =
  FinishTotals(known: true, cpuUserMicros: micros, cpuSysMicros: 0)

proc snap(ledger: CapacityLedger; leases: seq[LeaseFigure];
          now: int64): CapacitySnapshot =
  snapshot(ledger.copyFor(leases, 4000, now))

proc names(s: CapacitySnapshot): seq[string] =
  for group in s.groups:
    result.add(group.name)

suite "capacity counters":
  test "a finish without totals is counted apart, never as zero CPU":
    var ledger: CapacityLedger
    ledger.touchGroup("1000/a", 0)
    ledger.noteFinish("1000/a", totals(7_000_000), 0)
    ledger.noteFinish("1000/a", FinishTotals(known: false), 0)
    let group = ledger.groups["1000/a"].counters
    check group.cpuUsedMicros == 7_000_000
    check group.finishedWithTotals == 1
    check group.finishedWithoutTotals == 1
    check ledger.host == group

  test "counters saturate rather than wrap":
    check saturatingAdd(high(uint64) - 1, 5) == high(uint64)
    check saturatingAdd(3, 4) == 7
    check finishCpuMicros(FinishTotals(known: true,
      cpuUserMicros: high(uint64), cpuSysMicros: 2)) == high(uint64)

  test "grants and waits are counted per group and for the host":
    var ledger: CapacityLedger
    ledger.noteGrant("1000/a", 120, 0)
    ledger.noteGrant("1000/b", 30, 0)
    ledger.noteGrant("", 5, 0)
    check ledger.groups["1000/a"].counters.waitMillis == 120
    check ledger.host.grants == 3
    check ledger.host.waitMillis == 155

suite "idle groups drop out":
  test "after an hour without activity, unless the group is working":
    var ledger: CapacityLedger
    ledger.touchGroup("1000/idle", 0)
    ledger.touchGroup("1000/working", 0)
    let holding = @[LeaseFigure(groupKey: "1000/working", queued: false,
      cpuMilli: 2000, memoryBytes: 1024)]
    check snap(ledger, holding, Hour - 1).names == @["idle", "working"]
    let later = snap(ledger, holding, Hour)
    check later.names == @["working"]
    check later.groups[0].live.cpuGrantedMilli == 2000
    # The host's counters never drop out with a group.
    ledger.noteFinish("1000/idle", totals(5_000_000), 10)
    let afterPrune = snap(ledger, holding, 10 + Hour)
    check afterPrune.hostCounters.cpuUsedMicros == 5_000_000
    check afterPrune.names == @["working"]
    ledger.pruneIdleGroups(toHashSet(["1000/working"]), 10 + Hour)
    check not ledger.groups.hasKey("1000/idle")
    check ledger.groups.hasKey("1000/working")
    check ledger.host.cpuUsedMicros == 5_000_000

  test "a queued request keeps its group, and is shown as pending":
    var ledger: CapacityLedger
    ledger.touchGroup("1000/q", 0)
    let queued = @[LeaseFigure(groupKey: "1000/q", queued: true,
      waitedMillis: uint64(Hour + 5))]
    let s = snap(ledger, queued, 2 * Hour)
    check s.names == @["q"]
    check s.groups[0].live.pendingRequests == 1
    check s.groups[0].live.oldestPendingWaitMillis == uint64(Hour + 5)
    check s.hostLive.pendingRequests == 1

  test "no more than the cap of idle groups is kept, the newest first":
    var ledger: CapacityLedger
    for i in 0 ..< MaxRetainedIdleGroups + 76:
      ledger.touchGroup("1000/g" & $i, int64(i))
    ledger.pruneIdleGroups(initHashSet[string](), MaxRetainedIdleGroups + 76)
    check ledger.groups.len == MaxRetainedIdleGroups
    check not ledger.groups.hasKey("1000/g0")
    check not ledger.groups.hasKey("1000/g75")
    check ledger.groups.hasKey("1000/g76")

suite "labels":
  test "owner and name come from the group key":
    var known: bool
    var uid: int64
    var name: string
    groupKeyParts("1000/ci/job:7", known, uid, name)
    check known and uid == 1000 and name == "ci/job:7"
    groupKeyParts("?/x", known, uid, name)
    check not known and name == "x"

  test "names that are not UTF-8 stay distinct series":
    var ledger: CapacityLedger
    ledger.touchGroup("1000/n\xff", 0)
    ledger.touchGroup("1000/n\xfe", 0)
    ledger.touchGroup("1000/q\"b\\s", 0)
    let text = expositionText(snap(ledger, @[], 1))
    check "group=\"n\xEF\xBF\xBD\",group_hex=\"6eff\"" in text
    check "group=\"n\xEF\xBF\xBD\",group_hex=\"6efe\"" in text
    check "group=\"q\\\"b\\\\s\"}" in text
    let json = capacityJson(snap(ledger, @[], 1), "null")
    check "\"name\":\"n\xEF\xBF\xBD\"" in json
    check "\xff" notin json
