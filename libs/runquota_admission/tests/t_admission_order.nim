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
## The configured order (`AdmissionPolicy.order`), `fair-share` and
## `share-between-users = none` are checked here as well: the integration file
## drives `fair-share` end to end, but the validation of an order, the
## figure's arithmetic and the division between owners are clearest on the
## pure order.
##
## Each case names the change that makes it fail.

import std/[math, strutils, tables, unittest]

import runquota_core
import runquota_admission

proc request(id: uint64; owner = "1000"; priority = sessionPriorityNormal;
             deadline = 0'u64; arrival = 1'u64; rank = 0;
             waited = 0'i64; group = ""; fairShare = 0.0): PendingRequest =
  PendingRequest(id: id, owner: owner, groupPriority: priority,
    cacheDeadlinePresent: deadline != 0'u64, cacheDeadlineUnixMillis: deadline,
    groupArrival: arrival, localRank: rank, queueOrder: id,
    waitedMillis: waited, groupKey: group, fairShareCpu: fairShare)

proc order(requests: openArray[PendingRequest];
           load = initTable[string, OwnerLoad]();
           maxWait = 0'i64; keys: seq[AdmissionKey] = @[];
           share = sbuDrf): seq[uint64] =
  var plan = planAdmission(requests, load, AdmissionPolicy(
    order: keys, shareBetweenUsers: share,
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

suite "configured admission order":
  test "parsing accepts the five keys in any order":
    var keys: seq[AdmissionKey]
    var error = ""
    check parseAdmissionOrder(["fair-share", "arrival", "starvation",
      "cache-deadline", "priority"], keys, error)
    check keys == @[akFairShare, akArrival, akStarvation, akCacheDeadline,
      akPriority]
    check parseAdmissionOrder(["arrival"], keys, error)
    check keys == @[akArrival]

  test "parsing refuses an unknown key, a repeated key and an empty list":
    # Accepting any of them would put a guessed order in force.
    var keys: seq[AdmissionKey]
    var error = ""
    check not parseAdmissionOrder(["starvation", "fairshare"], keys, error)
    check "unknown admission.order key `fairshare`" in error
    check not parseAdmissionOrder(["Priority"], keys, error)
    check "unknown" in error
    check not parseAdmissionOrder(["priority", "arrival", "priority"], keys,
      error)
    check "twice" in error
    check not parseAdmissionOrder(newSeq[string](), keys, error)
    check "empty" in error

  test "share-between-users spellings":
    var share = sbuNone
    check parseShareBetweenUsers("drf", share) and share == sbuDrf
    check parseShareBetweenUsers("none", share) and share == sbuNone
    check not parseShareBetweenUsers("DRF", share)
    check not parseShareBetweenUsers("", share)

  test "an empty policy order is the default order":
    check AdmissionPolicy().effectiveOrder == @DefaultAdmissionOrder
    check DefaultAdmissionOrder == [akStarvation, akPriority, akCacheDeadline,
      akArrival]

  test "the configured order is the one applied":
    # [arrival] alone: the urgent group that became busy later waits for the
    # low one. Ignoring the configured order serves the urgent one first.
    let requests = [
      request(1, priority = sessionPriorityLow, arrival = 1),
      request(2, priority = sessionPriorityUrgent, arrival = 2)]
    check order(requests) == @[2'u64, 1]
    check order(requests, keys = @[akArrival]) == @[1'u64, 2]
    # [cache-deadline, priority]: the deadline now outranks priority.
    let byDeadline = [
      request(1, priority = sessionPriorityUrgent, arrival = 1),
      request(2, priority = sessionPriorityLow, arrival = 2, deadline = 9)]
    check order(byDeadline) == @[1'u64, 2]
    check order(byDeadline, keys = @[akCacheDeadline, akPriority]) ==
      @[2'u64, 1]

  test "arrival ends every order, listed or not":
    # [priority] alone still orders equal priorities by group arrival, then
    # class, then the request's own arrival.
    check order([request(3, arrival = 2), request(1, arrival = 1, rank = 1),
      request(2, arrival = 1)], keys = @[akPriority]) == @[2'u64, 1, 3]

  test "an order without starvation has no bound":
    # Request 2 has waited past the bound, but the order does not list
    # starvation: it is not starved, and priority decides. Applying the bound
    # regardless serves 2 first.
    let requests = [request(1, priority = sessionPriorityHigh),
      request(2, priority = sessionPriorityLow, waited = 10_000)]
    check order(requests, maxWait = 500) == @[2'u64, 1]
    check order(requests, maxWait = 500,
      keys = @[akPriority, akCacheDeadline, akArrival]) == @[1'u64, 2]
    var plan = planAdmission(requests, initTable[string, OwnerLoad](),
      AdmissionPolicy(maxWaitMillis: 500, order: @[akPriority, akArrival]))
    var next: PendingRequest
    while plan.next(next):
      check not next.starved

  test "starvation listed after priority is a bound among equals":
    let requests = [request(1, priority = sessionPriorityHigh, arrival = 1),
      request(2, priority = sessionPriorityLow, arrival = 2, waited = 9_000),
      request(3, priority = sessionPriorityLow, arrival = 3, waited = 10),
      request(4, priority = sessionPriorityLow, arrival = 1, waited = 10)]
    # 2 is starved: ahead of the other low requests, behind the high one.
    check order(requests, maxWait = 500,
      keys = @[akPriority, akStarvation, akArrival]) == @[1'u64, 2, 4, 3]

suite "fair-share":
  test "the smaller decayed figure goes first":
    # Group b has used less recently, so it goes before a, which became busy
    # first. Comparing the figures the wrong way round, or ignoring them,
    # serves a first.
    let requests = [
      request(1, arrival = 1, group = "a", fairShare = 5_000.0),
      request(2, arrival = 2, group = "b", fairShare = 100.0)]
    check order(requests) == @[1'u64, 2]
    check order(requests, keys = @[akStarvation, akFairShare, akArrival]) ==
      @[2'u64, 1]

  test "one pass spreads its grants between busy groups":
    # Three groups with nothing recent each queue three requests. Without the
    # plan raising a group's figure as it grants, a pass serves a, a, a.
    var requests: seq[PendingRequest] = @[]
    var id = 1'u64
    for (group, arrival) in [("a", 1'u64), ("b", 2'u64), ("c", 3'u64)]:
      for _ in 0 ..< 3:
        requests.add(request(id, arrival = arrival, group = group))
        inc id
    var plan = planAdmission(requests, initTable[string, OwnerLoad](),
      AdmissionPolicy(order: @[akStarvation, akFairShare, akArrival],
        capacityCpuMilli: 9000, capacityMemoryBytes: 9000))
    var served: seq[string] = @[]
    var next: PendingRequest
    while plan.next(next):
      served.add(next.groupKey)
      plan.noteGranted(next.owner, 1000, 0, next.groupKey)
    check served == @["a", "b", "c", "a", "b", "c", "a", "b", "c"]

  test "the decayed figure halves every half-life":
    # 60 s with nothing held halves it; holding h for ever converges on
    # h * H / ln 2, which is also what `committedCpu` charges up front.
    check abs(decayedCpu(1000.0, 0, FairShareHalfLifeMillis) - 500.0) < 1e-6
    check abs(decayedCpu(1000.0, 0, 2 * FairShareHalfLifeMillis) - 250.0) <
      1e-6
    check decayedCpu(1000.0, 0, 0) == 1000.0
    let horizon = float64(FairShareHalfLifeMillis) / 1000.0 / ln(2.0)
    check abs(decayedCpu(0.0, 2000, 100 * FairShareHalfLifeMillis) -
      2000.0 * horizon) < 1e-3
    check abs(committedCpu(2000) - 2000.0 * horizon) < 1e-9
    # One half-life of holding h from nothing reaches half the limit.
    check abs(decayedCpu(0.0, 1000, FairShareHalfLifeMillis) -
      0.5 * 1000.0 * horizon) < 1e-6
    check fairShareFigure(10.0, 1000) == 10.0 + committedCpu(1000)

type
  SimGroup = object
    ## One always-busy group of the fair-share simulation below: every
    ## request it makes is `cpuMilli` wide and, once granted, holds for
    ## `leaseMillis`.
    name: string
    cpuMilli: uint64
    leaseMillis: int64
    arrival: uint64

proc simulateFairShare(groups: openArray[SimGroup]; capacity: uint64;
                       keys: seq[AdmissionKey]; maxWait, totalMillis,
                       warmupMillis: int64): Table[string, float64] =
  ## CPU held x time per group, after `warmupMillis`, over `totalMillis` of
  ## simulated time in 1 s steps. Every step ends the leases that are due,
  ## tops each group's queue up to the whole host, runs one admission pass
  ## the way `runquotad` does (grant what fits, pass over what does not,
  ## stop at a starved request that does not fit) and advances each group's
  ## decayed figure with `decayedCpu`, as the daemon does on every change of
  ## what a group holds.
  ##
  ## A SIMULATION, NOT A MOCK: the order under test is the real library; the
  ## loop stands in for the clock and for builds that end, which is what
  ## lets an hour of turnover run deterministically in milliseconds. The
  ## daemon end of the same figure is `fair_share_order` and
  ## `fair_share_unequal_sizes` in tests/integration/t_session_group_admission.
  const Step = 1000'i64
  type Running = tuple[group: string, cpu: uint64, endsAt: int64]
  var held, sizes, durations = initTable[string, uint64]()
  var arrivals = initTable[string, uint64]()
  var recent = initTable[string, float64]()
  var running: seq[Running] = @[]
  var queue: seq[tuple[id: uint64, group: string, queuedAt: int64]] = @[]
  var nextId = 1'u64
  var free = capacity
  for g in groups:
    held[g.name] = 0
    sizes[g.name] = g.cpuMilli
    durations[g.name] = uint64(g.leaseMillis)
    arrivals[g.name] = g.arrival
    recent[g.name] = 0.0
    result[g.name] = 0.0
  var now = 0'i64
  while now < totalMillis:
    var still: seq[Running] = @[]
    for lease in running:
      if lease.endsAt <= now:
        held[lease.group] -= lease.cpu
        free += lease.cpu
      else:
        still.add(lease)
    running = still
    for g in groups:
      var queued = 0
      for entry in queue:
        if entry.group == g.name:
          inc queued
      while queued < int(capacity div g.cpuMilli):
        queue.add((nextId, g.name, now))
        inc nextId
        inc queued
    var pending: seq[PendingRequest] = @[]
    for entry in queue:
      pending.add(PendingRequest(id: entry.id, owner: "1000",
        groupPriority: sessionPriorityNormal,
        groupArrival: arrivals[entry.group], queueOrder: entry.id,
        waitedMillis: now - entry.queuedAt, groupKey: entry.group,
        fairShareCpu: fairShareFigure(recent[entry.group], held[entry.group])))
    var plan = planAdmission(pending, initTable[string, OwnerLoad](),
      AdmissionPolicy(order: keys, maxWaitMillis: maxWait,
        capacityCpuMilli: capacity, capacityMemoryBytes: 1))
    var granted: seq[uint64] = @[]
    var next: PendingRequest
    while plan.next(next):
      let size = sizes[next.groupKey]
      if size <= free:
        free -= size
        held[next.groupKey] += size
        running.add((next.groupKey, size,
          now + int64(durations[next.groupKey])))
        granted.add(next.id)
        plan.noteGranted(next.owner, size, 0, next.groupKey)
      elif next.starved:
        break
    var left: seq[tuple[id: uint64, group: string, queuedAt: int64]] = @[]
    for entry in queue:
      if entry.id notin granted:
        left.add(entry)
    queue = left
    for g in groups:
      if now >= warmupMillis:
        result[g.name] += float64(held[g.name]) * float64(Step)
      recent[g.name] = decayedCpu(recent[g.name], held[g.name], Step)
    now += Step

proc sharesWithin(held: Table[string, float64]; tolerance: float64): bool =
  ## Whether every group's CPU x time is within `tolerance` of the mean.
  var total = 0.0
  for value in held.values:
    total += value
  let mean = total / float64(held.len)
  result = mean > 0.0
  for name, value in held:
    echo "    " & name & ": " & formatFloat(value / total, ffDecimal, 3)
    if abs(value - mean) > tolerance * mean:
      result = false

suite "fair-share over time":
  # Busy groups whose requests differ in width, and whose leases differ in
  # length, hold equal CPU over time, within 10%. A group cannot take more by
  # asking in smaller pieces (which backfill fits first) or in larger ones
  # (which the charge per grant must count by width). Charging a grant a
  # fixed amount whatever its width gives the wider group more (57% here).
  # The default order is the control: it is first come first served.
  const Hour = 3_600_000'i64
  const Warmup = 600_000'i64
  let fs = @[akStarvation, akFairShare, akArrival]

  test "requests of 2 and 1 CPUs":
    let groups = [
      SimGroup(name: "wide", cpuMilli: 2000, leaseMillis: 10_000, arrival: 1),
      SimGroup(name: "narrow", cpuMilli: 1000, leaseMillis: 10_000,
        arrival: 2)]
    check sharesWithin(simulateFairShare(groups, 6000, fs, 120_000, Hour,
      Warmup), 0.10)
    # The control: under the default order the group that arrived first
    # keeps the host.
    check not sharesWithin(simulateFairShare(groups, 6000, @[], 120_000, Hour,
      Warmup), 0.10)

  test "requests of 1 and 4 CPUs, leases of 7 s and 13 s, with and without a bound":
    let groups = [
      SimGroup(name: "narrow", cpuMilli: 1000, leaseMillis: 7_000, arrival: 1),
      SimGroup(name: "wide", cpuMilli: 4000, leaseMillis: 13_000, arrival: 2)]
    check sharesWithin(simulateFairShare(groups, 8000, fs, 120_000, Hour,
      Warmup), 0.10)
    check sharesWithin(simulateFairShare(groups, 8000, @[akFairShare], 0,
      Hour, Warmup), 0.10)

  test "equal widths, leases of 5 s and 20 s":
    let groups = [
      SimGroup(name: "short", cpuMilli: 1000, leaseMillis: 5_000, arrival: 1),
      SimGroup(name: "long", cpuMilli: 1000, leaseMillis: 20_000, arrival: 2)]
    check sharesWithin(simulateFairShare(groups, 6000, fs, 120_000, Hour,
      Warmup), 0.10)

suite "share-between-users = none":
  test "no division between owners: one share, ordered across them":
    # Owner 1000 holds half the host and owner 2000 nothing. Under drf,
    # 2000's request goes first. Under none there is no division, and 1000's
    # group, which became busy first, goes first. Keeping DRF under none
    # serves 2 first.
    var load = initTable[string, OwnerLoad]()
    load["1000"] = OwnerLoad(cpuMilli: 2000, memoryBytes: 0)
    let requests = [request(1, owner = "1000", arrival = 1),
      request(2, owner = "2000", arrival = 2)]
    check order(requests, load) == @[2'u64, 1]
    check order(requests, load, share = sbuNone) == @[1'u64, 2]

  test "under none, one owner's group priority still ranks only its own":
    # The urgent group of owner 2000 does NOT go before owner 1000's normal
    # group that became busy first: group attributes are set by their owner
    # and rank only that owner's requests, under every division. Ordering
    # every owner's requests as one list by the full order serves 2 first.
    let requests = [request(1, owner = "1000", arrival = 1),
      request(2, owner = "2000", priority = sessionPriorityUrgent,
        arrival = 2)]
    check order(requests) == @[1'u64, 2]
    check order(requests, share = sbuNone) == @[1'u64, 2]
    # Nor does a cache deadline.
    let byDeadline = [request(1, owner = "1000", arrival = 1),
      request(2, owner = "2000", arrival = 2, deadline = 5)]
    check order(byDeadline, share = sbuNone) == @[1'u64, 2]

  test "under none, priority orders one owner's requests":
    # Owner 1000's urgent request (its group became busy at 3) goes before
    # its own low one (busy at 1). Between owners, the next requests are
    # compared by arrival: 2000's (busy at 2) before 1000's urgent one.
    # Dropping priority within an owner serves 1 before 3.
    let requests = [
      request(1, owner = "1000", priority = sessionPriorityLow, arrival = 1),
      request(2, owner = "2000", arrival = 2),
      request(3, owner = "1000", priority = sessionPriorityUrgent,
        arrival = 3)]
    check order(requests, share = sbuNone) == @[2'u64, 3, 1]

  test "under none, fair-share and starvation compare owners":
    # The keys the daemon measures do decide between owners: owner 2000's
    # group has used less recently, so it goes first though owner 1000's
    # became busy first; and a starved request goes before both.
    let requests = [
      request(1, owner = "1000", arrival = 1, group = "a", fairShare = 5_000.0),
      request(2, owner = "2000", arrival = 2, group = "b", fairShare = 100.0)]
    let fs = @[akStarvation, akFairShare, akArrival]
    check order(requests, keys = fs, share = sbuNone) == @[2'u64, 1]
    # Under drf with equal (zero) loads, the tie goes to arrival.
    check order(requests, keys = fs) == @[1'u64, 2]
    let starved = [
      request(1, owner = "1000", arrival = 1, group = "a"),
      request(2, owner = "2000", arrival = 2, group = "b", waited = 9_000)]
    check order(starved, maxWait = 500, keys = fs, share = sbuNone) ==
      @[2'u64, 1]
