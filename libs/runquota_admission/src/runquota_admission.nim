## The order in which RunQuota tries queued lease requests.
##
## A host-wide daemon serves several sessions at once, and when they all want
## CPU it has to decide who goes first. The discipline, in the order it is
## applied:
##
## 1. **Between owners: dominant-resource fairness** (`ShareBetweenUsers`
##    `sbuDrf`, the default). The owner (a uid, read from peer credentials)
##    whose granted leases hold the smallest share of the host -- the larger
##    of its CPU share and its memory share -- goes first. Capacity an owner
##    does not want is lent to the others, and nothing granted is ever
##    revoked; this only decides who is offered the next free capacity.
##    With `sbuNone` there is no division: the next owner served is the one
##    whose next request goes first under the configured order WITHOUT the
##    owner-set keys (`priority`, `cache-deadline`) -- see `crossOwnerOrder`.
## 2. **Within one owner's share, the configured order**
##    (`AdmissionPolicy.order`),
##    a list of `AdmissionKey`s applied in turn, each consulted only where
##    the ones before it tie. The default is `DefaultAdmissionOrder`:
##
##    * `starvation` -- a request that has waited at least
##      `AdmissionPolicy.maxWaitMillis` goes before the requests the keys
##      after it would rank, oldest first. The caller HOLDS capacity for it:
##      when such a request does not fit the free capacity, nothing behind
##      it is granted, so the slots that free up go to it and not to a
##      request that arrived later. (A request stopped by something freed
##      capacity does not cure, such as memory pressure, is passed over
##      instead; that is the caller's decision.) Left out of the order, no
##      request is starved and nothing is held.
##    * `priority` -- the group's priority, higher first;
##    * `cache-deadline` -- the group's prompt-cache deadline, earliest
##      first; a group with no deadline sorts after every group with one;
##    * `fair-share` -- the group's decayed CPU figure, smaller first
##      (`fairShareFigure`), so busy groups converge on equal shares;
##    * `arrival` -- the group that became busy first, and within one group
##      the request's own priority class and its arrival.
##
##    Every order ends with `arrival`, listed or not, so it is total.
##
## A request that does not fit is skipped and the next one tried (backfill),
## unless it is held under `starvation`.
##
## WHY THE DEFAULT IS FIRST COME FIRST SERVED AND NOT AN EQUAL SPLIT. Dividing
## the host equally between busy groups slows every concurrent build; serving
## the group that arrived first until it is done shortens the average wait,
## and the waits that matter -- a session whose prompt cache is about to
## expire -- are served by the priority and deadline keys above it. A host
## that wants equal shares says so with `fair-share`.
##
## This module is pure: it holds no daemon state and does no I/O, so the order
## can be tested without a daemon. The daemon builds the inputs from its lease
## table, asks `next` for a request, checks whether it fits, and reports each
## grant back with `noteGranted` so the owners' shares and the groups'
## fair-share figures stay current for the rest of the pass.

import std/[algorithm, math, strutils, tables]

import runquota_admission/types

export types

const libraryName* = "runquota_admission"

const DefaultMaxWaitMillis* = 120_000'i64
  ## The default starvation bound: two minutes, below the shortest provider
  ## prompt-cache lifetime (five minutes), so a session held back by others
  ## still runs before its cache goes cold.

const DefaultAdmissionOrder* = [akStarvation, akPriority, akCacheDeadline,
    akArrival]
  ## The order when the host configures none.

const FairShareHalfLifeMillis* = 60_000'i64
  ## How fast a group's fair-share figure forgets: each moment's CPU counts
  ## half as much a minute later. Short enough that a session is not held
  ## back for a build it finished minutes ago, long enough that a group
  ## whose leases just ended does not win the next slot straight back.

proc libraryInfo*(): LibraryInfo =
  LibraryInfo(name: libraryName)

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

proc parseAdmissionKey*(text: string; key: var AdmissionKey): bool =
  ## The key `text` spells, exactly (no case folding: the file's spelling is
  ## the one the status output prints back).
  for candidate in AdmissionKey:
    if $candidate == text:
      key = candidate
      return true
  false

proc parseAdmissionOrder*(names: openArray[string]; order: var seq[AdmissionKey];
                          error: var string): bool =
  ## Validate a configured order. Refused, with `error` saying why: an empty
  ## list (plain arrival order is written `[arrival]`), a key that is not one
  ## of `AdmissionKey`, and a key listed twice (it could only be a mistake
  ## about where it was meant to go).
  order = @[]
  if names.len == 0:
    error = "admission.order is empty; list at least one key (arrival " &
      "order alone is [\"arrival\"])"
    return false
  for name in names:
    var key: AdmissionKey
    if not parseAdmissionKey(name, key):
      var known: seq[string] = @[]
      for candidate in AdmissionKey:
        known.add($candidate)
      error = "unknown admission.order key `" & name & "`; expected " &
        known.join(", ")
      return false
    if key in order:
      error = "admission.order lists `" & name & "` twice"
      return false
    order.add(key)
  true

proc parseShareBetweenUsers*(text: string; share: var ShareBetweenUsers): bool =
  for candidate in ShareBetweenUsers:
    if $candidate == text:
      share = candidate
      return true
  false

proc effectiveOrder*(policy: AdmissionPolicy): seq[AdmissionKey] =
  ## The order in force: the configured one, or the default when none is set.
  if policy.order.len == 0: @DefaultAdmissionOrder else: policy.order

# ---------------------------------------------------------------------------
# The fair-share figure
# ---------------------------------------------------------------------------

proc decayFactor(elapsedMillis: int64): float64 =
  if elapsedMillis <= 0: 1.0
  else: pow(0.5, float64(elapsedMillis) / float64(FairShareHalfLifeMillis))

proc decayedCpu*(figure: float64; heldCpuMilli: uint64;
                 elapsedMillis: int64): float64 =
  ## Bring a group's decayed past CPU forward by `elapsedMillis`, during
  ## which it held `heldCpuMilli` throughout. Milli-CPU x seconds.
  ##
  ## The figure is the integral of held CPU with each moment weighted by
  ## 2^(-age / half-life). Over an interval of length t with constant held
  ## CPU h, the old figure decays by d = 2^(-t/H) and the interval adds
  ## h * (H / ln 2) * (1 - d) -- the closed form of that integral.
  let d = decayFactor(elapsedMillis)
  let horizonSeconds = float64(FairShareHalfLifeMillis) / 1000.0 / ln(2.0)
  figure * d + float64(heldCpuMilli) * horizonSeconds * (1.0 - d)

proc committedCpu*(heldCpuMilli: uint64): float64 =
  ## What leases holding `heldCpuMilli` now will add to the decayed figure if
  ## they keep running: h * H / ln 2 (the integral of h * 2^(-t/H) over all
  ## future t). Counting it is what lets one pass spread the slots it frees
  ## between busy groups.
  float64(heldCpuMilli) * float64(FairShareHalfLifeMillis) / 1000.0 / ln(2.0)

proc fairShareFigure*(decayedPast: float64; heldCpuMilli: uint64): float64 =
  ## The figure `fair-share` orders by: the group's decayed past CPU (brought
  ## up to now with `decayedCpu`) plus `committedCpu` of what it holds now.
  decayedPast + committedCpu(heldCpuMilli)

# ---------------------------------------------------------------------------
# The order
# ---------------------------------------------------------------------------

proc isStarved*(request: PendingRequest; policy: AdmissionPolicy): bool =
  ## Whether `request` has waited at least the starvation bound, under an
  ## order that has one.
  policy.maxWaitMillis > 0 and request.waitedMillis >= policy.maxWaitMillis and
    akStarvation in policy.effectiveOrder

proc arrivalCmp(a, b: PendingRequest): int =
  ## `arrival`, which also ends every order: the group that became busy
  ## first, then within one group the request's class and its own arrival.
  if a.groupArrival != b.groupArrival:
    return cmp(a.groupArrival, b.groupArrival)
  if a.localRank != b.localRank:
    return cmp(a.localRank, b.localRank)
  cmp(a.queueOrder, b.queueOrder)

proc orderCmp*(a, b: PendingRequest; order: openArray[AdmissionKey];
               fairShareOf: proc (r: PendingRequest): float64 {.closure.} = nil):
    int =
  ## Compare two requests of one share under `order`; negative when `a` goes
  ## first. `fairShareOf`, when given, supplies the current fair-share figure
  ## (the plan raises it as it grants); otherwise the request's own
  ## `fairShareCpu` is used. The `starved` flags are set by `planAdmission`.
  for key in order:
    case key
    of akStarvation:
      if a.starved != b.starved:
        return (if a.starved: -1 else: 1)
      if a.starved:
        # Starved requests among themselves: oldest first.
        return cmp(a.queueOrder, b.queueOrder)
    of akPriority:
      if a.groupPriority != b.groupPriority:
        return (if a.groupPriority > b.groupPriority: -1 else: 1)
    of akCacheDeadline:
      if a.cacheDeadlinePresent != b.cacheDeadlinePresent:
        # A group whose cache will expire goes before one with none to lose.
        return (if a.cacheDeadlinePresent: -1 else: 1)
      if a.cacheDeadlinePresent and
          a.cacheDeadlineUnixMillis != b.cacheDeadlineUnixMillis:
        return cmp(a.cacheDeadlineUnixMillis, b.cacheDeadlineUnixMillis)
    of akFairShare:
      if a.groupKey != b.groupKey:
        let fa = if fairShareOf.isNil: a.fairShareCpu else: fairShareOf(a)
        let fb = if fairShareOf.isNil: b.fairShareCpu else: fairShareOf(b)
        if fa != fb:
          return cmp(fa, fb)
    of akArrival:
      let c = arrivalCmp(a, b)
      if c != 0:
        return c
  arrivalCmp(a, b)

proc groupOrderLess*(a, b: PendingRequest): bool =
  ## The DEFAULT order of two requests of one owner.
  orderCmp(a, b, DefaultAdmissionOrder) < 0

proc ownerTieLess*(a, b: PendingRequest): bool =
  ## Between the next requests of two owners whose dominant shares are equal
  ## (for example, both hold nothing yet). GROUP ATTRIBUTES ARE NOT CONSULTED:
  ## an owner sets its own groups' priority and cache deadline, and those rank
  ## only that owner's requests, so a user who marks every group `urgent`
  ## gains nothing over another user. A starved request goes first (only an
  ## order with `starvation` starves one), then the group that became busy
  ## first, then the request that arrived first.
  if a.starved != b.starved:
    return a.starved
  if a.groupArrival != b.groupArrival:
    return a.groupArrival < b.groupArrival
  a.queueOrder < b.queueOrder

proc crossOwnerOrder*(order: openArray[AdmissionKey]): seq[AdmissionKey] =
  ## The keys of `order` that may decide between two OWNERS' requests: every
  ## key but `priority` and `cache-deadline`. Those two are group attributes
  ## an owner sets for its own groups, and they rank only that owner's
  ## requests, whatever the division between owners is (reprobuild-specs
  ## Build-Engine-And-Scheduler.md, "Session groups"): otherwise a user who
  ## marks every group `urgent` would go before every other user. What is
  ## left -- `starvation`, `fair-share`, `arrival` -- the daemon measures; no
  ## client sets it.
  for key in order:
    if key notin {akPriority, akCacheDeadline}:
      result.add(key)

type
  AdmissionPlan* = object
    ## One pass over the queue. Build it with `planAdmission`, then call
    ## `next` until it returns false or the caller stops.
    policy: AdmissionPolicy
    order: seq[AdmissionKey]
    crossOrder: seq[AdmissionKey]
      ## `crossOwnerOrder(order)`: how `sbuNone` picks between owners.
    owners: seq[string]
      ## Owners with requests, in first-seen order of `requests`; kept as a
      ## sequence so iteration is deterministic. Each owner's requests are
      ## ordered on their own under both divisions, because the owner-set
      ## keys never compare two owners' requests.
    byOwner: Table[string, seq[PendingRequest]]
    cursor: Table[string, int]
    load: Table[string, OwnerLoad]
    fairShare: Table[string, float64]
      ## Each group's fair-share figure, raised by `noteGranted`.

proc sortRemaining(plan: var AdmissionPlan; owner: string) =
  ## Order what `owner` has not been offered yet, by the figures as they
  ## stand now.
  let figures = plan.fairShare
  let order = plan.order
  let figureOf = proc (r: PendingRequest): float64 =
    figures.getOrDefault(r.groupKey, r.fairShareCpu)
  let start = plan.cursor[owner]
  var tail = plan.byOwner[owner][start .. ^1]
  tail.sort(proc (a, b: PendingRequest): int = orderCmp(a, b, order, figureOf))
  for i, request in tail:
    plan.byOwner[owner][start + i] = request

proc crossOwnerLess(plan: AdmissionPlan; a, b: PendingRequest): bool =
  ## Under `sbuNone`: whether owner A's next request `a` goes before owner
  ## B's next request `b`, by `crossOwnerOrder` and the current figures.
  ## Comparing only the two owners' NEXT requests is what keeps the
  ## owner-set keys inside each owner (a comparison of arbitrary requests of
  ## two owners that skipped those keys would not be transitive).
  let figures = plan.fairShare
  let figureOf = proc (r: PendingRequest): float64 =
    figures.getOrDefault(r.groupKey, r.fairShareCpu)
  orderCmp(a, b, plan.crossOrder, figureOf) < 0

proc planAdmission*(requests: openArray[PendingRequest];
                    load: Table[string, OwnerLoad];
                    policy: AdmissionPolicy): AdmissionPlan =
  ## Order `requests` for one admission pass. `load` is what each owner's
  ## granted leases hold now; an owner absent from it holds nothing.
  result.policy = policy
  result.order = policy.effectiveOrder
  result.crossOrder = crossOwnerOrder(result.order)
  result.load = load
  for request in requests:
    var entry = request
    entry.starved = entry.isStarved(policy)
    if not result.fairShare.hasKey(entry.groupKey):
      result.fairShare[entry.groupKey] = entry.fairShareCpu
    if not result.byOwner.hasKey(entry.owner):
      result.byOwner[entry.owner] = @[]
      result.cursor[entry.owner] = 0
      result.owners.add(entry.owner)
    result.byOwner[entry.owner].add(entry)
  for owner in result.owners:
    result.sortRemaining(owner)

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
  var found = false
  var chosenShare = 0.0
  for owner in plan.owners:
    let position = plan.cursor[owner]
    if position >= plan.byOwner[owner].len:
      continue
    let head = plan.byOwner[owner][position]
    if plan.policy.shareBetweenUsers == sbuNone:
      # No division: the owner whose next request goes first by the keys
      # that may compare two owners.
      if not found or plan.crossOwnerLess(head,
          plan.byOwner[chosen][plan.cursor[chosen]]):
        chosen = owner
        found = true
      continue
    let share = plan.dominantShare(owner)
    if not found or share < chosenShare or
        (share == chosenShare and ownerTieLess(head,
          plan.byOwner[chosen][plan.cursor[chosen]])):
      chosen = owner
      chosenShare = share
      found = true
  if not found:
    return false
  request = plan.byOwner[chosen][plan.cursor[chosen]]
  inc plan.cursor[chosen]
  true

proc noteGranted*(plan: var AdmissionPlan; owner: string;
                  cpuMilli, memoryBytes: uint64; groupKey = "") =
  ## Record that the caller granted a request of `owner` in group `groupKey`,
  ## so the next `next` sees the owner's larger share and, under
  ## `fair-share`, the group's larger figure.
  var held = plan.load.getOrDefault(owner, OwnerLoad())
  held.cpuMilli += cpuMilli
  held.memoryBytes += memoryBytes
  plan.load[owner] = held
  if akFairShare in plan.order and plan.fairShare.hasKey(groupKey):
    plan.fairShare[groupKey] += committedCpu(cpuMilli)
    # Only this group's figure moved, and only upward; re-order what is left
    # of its owner's requests (`next` compares the owners' next requests by
    # the current figures too). Grants per pass are bounded by the host's
    # capacity, so this is a handful of sorts, not one per request tried.
    if plan.byOwner.hasKey(owner):
      plan.sortRemaining(owner)
