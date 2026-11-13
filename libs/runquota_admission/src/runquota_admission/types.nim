import runquota_core

type
  LibraryInfo* = object
    name*: string
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
      ## starvation bound.

  OwnerLoad* = object
    ## What one owner's granted leases hold right now.
    cpuMilli*: uint64
    memoryBytes*: uint64

  AdmissionPolicy* = object
    maxWaitMillis*: int64
      ## The starvation bound. Zero or negative turns it off.
    capacityCpuMilli*: uint64
    capacityMemoryBytes*: uint64
      ## The host budget the owners' dominant shares are fractions of.
