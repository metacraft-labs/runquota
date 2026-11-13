## The order in which RunQuota tries queued lease requests.
##
## A host-wide daemon serves several sessions at once, and when they all want
## CPU it has to decide who goes first. The discipline, in the order it is
## applied:
##
## 1. **Between owners: dominant-resource fairness.** The owner (a uid, read
##    from peer credentials) whose granted leases hold the smallest share of
##    the host -- the larger of its CPU share and its memory share -- goes
##    first. Capacity an owner does not want is lent to the others, and
##    nothing granted is ever revoked; this only decides who is offered the
##    next free capacity.
## 2. **Within one owner's share, the starvation bound.** A request that has
##    waited at least `AdmissionPolicy.maxWaitMillis` goes before the rest of
##    its owner's requests, oldest first. The caller HOLDS capacity for it:
##    when such a request does not fit the free capacity, nothing behind it
##    is granted, so the slots that free up go to it and not to a request
##    that arrived later. (A request stopped by something freed capacity
##    does not cure, such as memory pressure, is passed over instead; that
##    is the caller's decision.)
## 3. **Then the session group order** -- the group's priority (higher
##    first), then its prompt-cache deadline (earliest first; a group with no
##    deadline sorts after every group with one), then the group's arrival,
##    and within one group the request's own priority class and its
##    arrival.
##
## A request that does not fit is skipped and the next one tried (backfill),
## unless it is held under rule 2.
##
## WHY ARRIVAL IS FIRST COME FIRST SERVED AND NOT AN EQUAL SPLIT. Dividing the
## host equally between busy groups slows every concurrent build; serving the
## group that arrived first until it is done shortens the average wait, and
## the waits that matter -- a session whose prompt cache is about to expire --
## are served by the priority and deadline rules above it.
##
## This module is pure: it holds no daemon state and does no I/O, so the order
## can be tested without a daemon. The daemon builds the inputs from its lease
## table, asks `next` for a request, checks whether it fits, and reports each
## grant back with `noteGranted` so the owners' shares stay current.

import std/[algorithm, tables]

import runquota_admission/types

export types

const libraryName* = "runquota_admission"

const DefaultMaxWaitMillis* = 120_000'i64
  ## The default starvation bound: two minutes, below the shortest provider
  ## prompt-cache lifetime (five minutes), so a session held back by others
  ## still runs before its cache goes cold.

proc libraryInfo*(): LibraryInfo =
  LibraryInfo(name: libraryName)

proc isStarved*(request: PendingRequest; policy: AdmissionPolicy): bool =
  ## Whether `request` has waited at least the starvation bound.
  policy.maxWaitMillis > 0 and request.waitedMillis >= policy.maxWaitMillis

proc groupOrderLess*(a, b: PendingRequest): bool =
  ## The order of two requests of ONE owner (rules 2 and 3 above). The
  ## `starved` flag is set by `planAdmission`.
  if a.starved != b.starved:
    return a.starved
  if a.starved:
    # Starved requests among themselves: oldest first.
    return a.queueOrder < b.queueOrder
  if a.groupPriority != b.groupPriority:
    return a.groupPriority > b.groupPriority
  if a.cacheDeadlinePresent != b.cacheDeadlinePresent:
    # A group whose cache will expire goes before one with no cache to lose.
    return a.cacheDeadlinePresent
  if a.cacheDeadlinePresent and
      a.cacheDeadlineUnixMillis != b.cacheDeadlineUnixMillis:
    return a.cacheDeadlineUnixMillis < b.cacheDeadlineUnixMillis
  if a.groupArrival != b.groupArrival:
    return a.groupArrival < b.groupArrival
  if a.localRank != b.localRank:
    return a.localRank < b.localRank
  a.queueOrder < b.queueOrder

proc ownerTieLess*(a, b: PendingRequest): bool =
  ## Between the next requests of two owners whose dominant shares are equal
  ## (for example, both hold nothing yet). GROUP ATTRIBUTES ARE NOT CONSULTED:
  ## an owner sets its own groups' priority and cache deadline, and those rank
  ## only that owner's requests, so a user who marks every group `urgent`
  ## gains nothing over another user. A starved request goes first, then the
  ## group that became busy first, then the request that arrived first.
  if a.starved != b.starved:
    return a.starved
  if a.groupArrival != b.groupArrival:
    return a.groupArrival < b.groupArrival
  a.queueOrder < b.queueOrder

proc groupOrderCmp(a, b: PendingRequest): int =
  if groupOrderLess(a, b): -1
  elif groupOrderLess(b, a): 1
  else: 0

type
  AdmissionPlan* = object
    ## One pass over the queue. Build it with `planAdmission`, then call
    ## `next` until it returns false or the caller stops.
    policy: AdmissionPolicy
    owners: seq[string]
      ## Owners with requests, in first-seen order of `requests`; kept as a
      ## sequence so iteration is deterministic.
    byOwner: Table[string, seq[PendingRequest]]
    cursor: Table[string, int]
    load: Table[string, OwnerLoad]

proc planAdmission*(requests: openArray[PendingRequest];
                    load: Table[string, OwnerLoad];
                    policy: AdmissionPolicy): AdmissionPlan =
  ## Order `requests` for one admission pass. `load` is what each owner's
  ## granted leases hold now; an owner absent from it holds nothing.
  result.policy = policy
  result.load = load
  for request in requests:
    var entry = request
    entry.starved = entry.isStarved(policy)
    if not result.byOwner.hasKey(entry.owner):
      result.byOwner[entry.owner] = @[]
      result.cursor[entry.owner] = 0
      result.owners.add(entry.owner)
    result.byOwner[entry.owner].add(entry)
  for owner in result.owners:
    result.byOwner[owner].sort(groupOrderCmp)

proc dominantShare(plan: AdmissionPlan; owner: string): float64 =
  ## The larger of the owner's CPU and memory shares of the host. A zero
  ## capacity contributes nothing rather than dividing by zero.
  let held = plan.load.getOrDefault(owner, OwnerLoad())
  var cpuShare = 0.0
  var memoryShare = 0.0
  if plan.policy.capacityCpuMilli > 0'u64:
    cpuShare = float64(held.cpuMilli) / float64(plan.policy.capacityCpuMilli)
  if plan.policy.capacityMemoryBytes > 0'u64:
    memoryShare = float64(held.memoryBytes) /
      float64(plan.policy.capacityMemoryBytes)
  max(cpuShare, memoryShare)

proc next*(plan: var AdmissionPlan; request: var PendingRequest): bool =
  ## The next request to try, or false when every request has been offered.
  ## Each request is returned at most once per plan.
  var chosen = ""
  var chosenShare = 0.0
  for owner in plan.owners:
    let position = plan.cursor[owner]
    if position >= plan.byOwner[owner].len:
      continue
    let share = plan.dominantShare(owner)
    if chosen.len == 0 or share < chosenShare or
        (share == chosenShare and ownerTieLess(plan.byOwner[owner][position],
          plan.byOwner[chosen][plan.cursor[chosen]])):
      chosen = owner
      chosenShare = share
  if chosen.len == 0:
    return false
  request = plan.byOwner[chosen][plan.cursor[chosen]]
  inc plan.cursor[chosen]
  true

proc noteGranted*(plan: var AdmissionPlan; owner: string;
                  cpuMilli, memoryBytes: uint64) =
  ## Record that the caller granted a request of `owner`, so the next `next`
  ## sees the owner's larger share.
  var held = plan.load.getOrDefault(owner, OwnerLoad())
  held.cpuMilli += cpuMilli
  held.memoryBytes += memoryBytes
  plan.load[owner] = held
