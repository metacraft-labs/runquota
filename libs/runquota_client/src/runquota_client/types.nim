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

  RunQuotaLease* = object
    session*: ptr RunQuotaSession
    id*: LeaseId
    resources*: ResourceVector
    active*: bool
    state*: LeaseClientState

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
