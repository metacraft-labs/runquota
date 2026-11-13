## The admission order on its own, without a daemon.
##
## `tests/integration/t_session_group_admission` drives the order through a real
## `runquotad` with one user. Two parts of it need more than one OWNER, which
## a daemon on a single-user host never sees: dominant-resource fairness
## between owners, and the starvation bound applying within each owner's
## share. They are
## checked here, on the pure order the daemon calls.
##
## NO MOCKS: `runquota_admission` is pure, so these are its real inputs and
## outputs.
##
## Each case names the change that makes it fail.

import std/[tables, unittest]

import runquota_core
import runquota_admission

proc request(id: uint64; owner = "1000"; priority = sessionPriorityNormal;
             deadline = 0'u64; arrival = 1'u64; rank = 0;
             waited = 0'i64): PendingRequest =
  PendingRequest(id: id, owner: owner, groupPriority: priority,
    cacheDeadlinePresent: deadline != 0'u64, cacheDeadlineUnixMillis: deadline,
    groupArrival: arrival, localRank: rank, queueOrder: id,
    waitedMillis: waited)

proc order(requests: openArray[PendingRequest];
           load = initTable[string, OwnerLoad]();
           maxWait = 0'i64): seq[uint64] =
  var plan = planAdmission(requests, load, AdmissionPolicy(
    maxWaitMillis: maxWait, capacityCpuMilli: 4000, capacityMemoryBytes: 4096))
  var next: PendingRequest
  while plan.next(next):
    result.add(next.id)

suite "admission order":
  test "priority, then cache deadline (none last), then group arrival, then class and arrival":
    # Inverting any comparison in `groupOrderLess` reorders this list.
    check order([
      request(1, priority = sessionPriorityLow, arrival = 1),
      request(2, priority = sessionPriorityNormal, arrival = 2),
      request(3, priority = sessionPriorityNormal, arrival = 3,
        deadline = 9_000),
      request(4, priority = sessionPriorityNormal, arrival = 4,
        deadline = 5_000),
      request(5, priority = sessionPriorityUrgent, arrival = 5),
      request(6, priority = sessionPriorityNormal, arrival = 2, rank = 1),
      request(7, priority = sessionPriorityNormal, arrival = 2)]) ==
      @[5'u64, 4, 3, 2, 7, 6, 1]

  test "a group keeps the place it arrived at while it stays busy":
    # Group A (arrival 1) queued request 3 after group B (arrival 2) queued
    # request 2: A's later request still goes first. Ordering by the
    # request's own arrival instead interleaves the two groups.
    check order([request(2, arrival = 2), request(3, arrival = 1)]) ==
      @[3'u64, 2]

  test "within an owner, starved requests go first, oldest first":
    # Treat the bound as off and the starved low-priority requests go last.
    check order([
      request(1, priority = sessionPriorityUrgent),
      request(2, priority = sessionPriorityLow, waited = 900),
      request(3, priority = sessionPriorityLow, waited = 500)],
      maxWait = 500) == @[2'u64, 3, 1]
    var plan = planAdmission([request(9, waited = 500)],
      initTable[string, OwnerLoad](), AdmissionPolicy(maxWaitMillis: 500))
    var next: PendingRequest
    check plan.next(next) and next.starved

  test "the starvation bound applies within each owner's share":
    # The host is divided between owners first: owner 2000 holds less, so
    # its fresh request goes before owner 1000's starved one. Ranking starved
    # requests ahead of the division between owners reorders this.
    var load = initTable[string, OwnerLoad]()
    load["1000"] = OwnerLoad(cpuMilli: 2000, memoryBytes: 0)
    check order([request(1, owner = "1000", waited = 900),
      request(2, owner = "2000")], load, maxWait = 500) == @[2'u64, 1]

  test "a bound of zero is off":
    check order([request(1, priority = sessionPriorityHigh),
      request(2, priority = sessionPriorityLow, waited = 1_000_000)]) ==
      @[1'u64, 2]

  test "between owners, the smaller dominant share goes first":
    # Owner 1000 holds half the CPU, owner 2000 holds a quarter of the memory:
    # 2000's dominant share is smaller, so its normal request goes before
    # 1000's urgent one. Group attributes rank only their owner's requests.
    var load = initTable[string, OwnerLoad]()
    load["1000"] = OwnerLoad(cpuMilli: 2000, memoryBytes: 0)
    load["2000"] = OwnerLoad(cpuMilli: 0, memoryBytes: 1024)
    check order([request(1, owner = "1000", priority = sessionPriorityUrgent),
      request(2, owner = "2000")], load) == @[2'u64, 1]

  test "a grant raises its owner's share for the rest of the pass":
    # Equal shares fall back to the group order (1 before 2). After 1 is
    # granted, owner 1000 holds more than owner 2000, so 2000 goes next even
    # though 1000's second request ranks higher. Without `noteGranted` the
    # pass serves 1000 twice.
    var plan = planAdmission([
      request(1, owner = "1000", priority = sessionPriorityHigh),
      request(3, owner = "1000", priority = sessionPriorityHigh),
      request(2, owner = "2000")], initTable[string, OwnerLoad](),
      AdmissionPolicy(capacityCpuMilli: 4000, capacityMemoryBytes: 4096))
    var next: PendingRequest
    check plan.next(next) and next.id == 1'u64
    plan.noteGranted("1000", 1000, 0)
    check plan.next(next) and next.id == 2'u64
    plan.noteGranted("2000", 1000, 0)
    check plan.next(next) and next.id == 3'u64
    check not plan.next(next)

  test "between owners with equal shares, group attributes do not decide":
    # Neither owner holds anything. Owner 2000 marked its group urgent, but
    # owner 1000's group became busy first, so 1000's request goes first:
    # an owner's attributes rank only its own requests. Breaking the tie by
    # the group order hands it to 2000.
    check order([request(1, owner = "1000", arrival = 1),
      request(2, owner = "2000", priority = sessionPriorityUrgent,
        arrival = 2)]) == @[1'u64, 2]
