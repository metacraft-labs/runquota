import std/tables

import runquota_core
import runquota_codec
import runquota_ipc
import runquota_protocol

type
  LibraryInfo* = object
    name*: string

  ClientState* = enum
    csDisconnected
    csConnected
    csClosed

  LeaseClientState* = enum
    leaseClientQueued
    leaseClientGranted
    leaseClientStarting
    leaseClientRunning
    leaseClientFinished
    leaseClientReleased

  RunQuotaClient* = object
    connection*: LocalConnection
    nextRequestId*: uint64
    state*: ClientState
    daemonId*: uint64
    daemonVersion*: string
    capabilities*: CapabilityRecord
    flow*: FlowControlLimits
    lastDiagnostic*: Diagnostic
    responseBuffer*: Table[uint64, RqspFrame]
    inflightRequestIds*: seq[uint64]
    socketClass*: string
      ## The reservation class whose socket this client connected to
      ## (`connectForClass`), or "" for the shared socket. The daemon's
      ## `HelloOk` on a class socket names the same class.

  RunQuotaSession* = object
    client*: ptr RunQuotaClient
    id*: SessionId
    active*: bool
    ## ``pendingGrantRequestId`` tracks an in-flight ``GrantNext`` whose
    ## response has not yet been read.  It lets a bounded grant poll
    ## (``pollNextGrantBounded``) wait for the *same* request across
    ## several short reads — a daemon that legitimately keeps a candidate
    ## queued answers with an empty batch and the id is cleared; a daemon
    ## that is silent leaves the id set so the next bounded read continues
    ## waiting on it instead of flooding the daemon with fresh GrantNext
    ## frames (which would buffer unbounded late responses).  ``0`` means
    ## "no GrantNext is currently outstanding".
    pendingGrantRequestId*: uint64
    groupName*: string
      ## The session group this session joined (`interactive` when it
      ## named none).
    declaredGroupPriority*: SessionPriority
      ## The priority this session would have created its group with.
    groupPriorityKnown*: bool
    groupPriority*: SessionPriority
      ## The group's priority in force, once `groupPriorityInForce` asked.

  RunQuotaLease* = object
    session*: ptr RunQuotaSession
    id*: LeaseId
    resources*: ResourceVector
    active*: bool
    state*: LeaseClientState
    reclaimed*: bool
      ## The daemon granted this lease into PREDICTED slack (the running
      ## leases' tails), not into free capacity: the launcher must run its
      ## tree at the lower weight. Only ever true for a request that
      ## accepted it (``acceptingReclaimed``).
    expectedUncontendedMillis*: uint64
      ## After a ``finish`` that asked for it (``askExpectedDuration``), the
      ## daemon's learned expected uncontended duration of this command at
      ## its granted width; 0 when the daemon knew none or was not asked.
    memoryCap*: GrantMemoryCap
      ## The memory cap the daemon computed for this lease at the grant
      ## (`MemoryCapMinor`): the launcher enforces it, measures it, or says
      ## why it could not (`runquota_exec.resolveMemoryCap`). `known` is
      ## false for a daemon below that minor and for a lease without a
      ## memory dimension (a sub-lease runs inside its parent's cap).

  OfferedLease* = object
    clientCandidateId*: uint64
    lease*: RunQuotaLease
    queued*: bool
    diagnostic*: Diagnostic

  ResourceRequest* = object
    label*: string
    commandStatsId*: string
    resources*: ResourceVector
    deadline*: Deadline
    priority*: PriorityClass
    purpose*: LeasePurpose
    metadata*: DynamicMetadata
    estimate*: ClientEstimate
      ## What the CLIENT already believes this work costs, from its own
      ## cache or from the published aggregate table. Absent by default:
      ## a client that caches nothing and never estimates must keep
      ## working, and for it the daemon's learned table remains the
      ## fallback exactly as before. See ``withEstimate``.
    width*: WidthRange
      ## A CPU range instead of one value (``withWidthRange``). Sent only to
      ## a daemon at ``NegotiatedWidthsMinor`` or above; to an older one the
      ## request asks for exactly ``resources.cpu``.
