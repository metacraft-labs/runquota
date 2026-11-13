import runquota_core

type
  LibraryInfo* = object
    name*: string
  AdmissionKey* = enum
    ## One key of the configured admission order (`admission.order` in the
    ## host file). The string is the spelling the file and the status output
    ## use.
    akStarvation = "starvation"
      ## A request that has waited at least the bound goes first, and freed
      ## capacity is held for it.
    akPriority = "priority"
      ## Higher session group priority first.
    akCacheDeadline = "cache-deadline"
      ## Earliest group cache deadline first; none after every deadline.
    akFairShare = "fair-share"
      ## The group with the smaller decayed CPU figure first.
    akArrival = "arrival"
      ## The group that became busy first; within a group, request class and
      ## then the request's own arrival.

  ShareBetweenUsers* = enum
    ## How the host is divided between owner uids before the order applies.
    sbuDrf = "drf"
      ## Dominant-resource fairness: each owner's share is ordered on its own.
    sbuNone = "none"
      ## No division by usage: owners are served by their next requests'
      ## order under the keys the daemon measures (`starvation`,
      ## `fair-share`, `arrival`). Group priority and cache deadline still
      ## rank only their owner's requests, as under `drf`.

  AdmissionDecision* = enum
    adGrant
    adQueue
    adDeny

  PendingRequest* = object
    ## One queued lease, reduced to the facts the admission ORDER depends on.
    ## The daemon owns everything else about it (its resources, whether it
    ## fits); this module only decides which queued request is tried next.
    id*: uint64
      ## The daemon's lease id. Opaque here.
    owner*: string
      ## The owner the daemon read from peer credentials, as a key. Requests
      ## of different owners are ordered by dominant-resource fairness before
      ## any group attribute is consulted, because a group's attributes are
      ## set by its owner and must rank only that owner's requests.
    groupPriority*: SessionPriority
    cacheDeadlinePresent*: bool
    cacheDeadlineUnixMillis*: uint64
    groupArrival*: uint64
      ## When the request's session group became busy: the queue position of
      ## the first request it made after it last had nothing queued or
      ## running. Arrival order is the order of GROUPS, not of individual
      ## requests, so a build that offers its work a few candidates at a time
      ## keeps the place it arrived at instead of interleaving with every
      ## build that arrived after it.
    localRank*: int
      ## The request's own priority class within its group, lower first: the
      ## per-invocation order the daemon already had before session groups.
    queueOrder*: uint64
      ## This request's own arrival position. Unique per daemon.
    waitedMillis*: int64
      ## How long the request has been queued.
    starved*: bool
      ## Set by `planAdmission`: the request has waited at least the
      ## starvation bound, and the order includes `starvation`.
    groupKey*: string
      ## The daemon's key for the request's session group. Requests with the
      ## same key share one fair-share figure; see `fairShareCpu`.
    fairShareCpu*: float64
      ## The group's fair-share figure when the pass starts, in
      ## milli-CPU x seconds: `fairShareFigure` of its decayed past and what
      ## it holds now. Every request of one group carries the same value;
      ## the plan raises it as it grants the group more.

  OwnerLoad* = object
    ## What one owner's granted leases hold right now.
    cpuMilli*: uint64
    memoryBytes*: uint64

  AdmissionPolicy* = object
    order*: seq[AdmissionKey]
      ## The configured order. EMPTY MEANS THE DEFAULT (`DefaultAdmissionOrder`),
      ## so a policy built without one orders as the daemon always has; a
      ## host file cannot ask for an empty order (its reader refuses it).
    shareBetweenUsers*: ShareBetweenUsers
    maxWaitMillis*: int64
      ## The starvation bound. Zero or negative turns it off, and so does an
      ## order without `starvation`.
    capacityCpuMilli*: uint64
    capacityMemoryBytes*: uint64
      ## The host budget the owners' dominant shares are fractions of.
