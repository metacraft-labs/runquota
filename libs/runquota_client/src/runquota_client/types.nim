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
    metadata*: DynamicMetadata
