import std/tables

import runquota_core
import runquota_ipc
import runquota_protocol

type
  LibraryInfo* = object
    name*: string

  DaemonState* = enum
    dsStarting
    dsServing
    dsStopping

  LeaseLifecycleState* = enum
    leaseStateGranted
    leaseStateStarting
    leaseStateRunning
    leaseStateFinished
    leaseStateSupervisorLost

  DaemonConfig* = object
    endpoint*: Endpoint
    daemonId*: uint64
    cpuSlots*: MilliCpu
    memoryBytes*: Bytes
    version*: string

  SessionRow* = object
    id*: SessionId
    name*: string
    version*: string
    supervisorProcessId*: uint64
    supervisorUserId*: uint64
    peer*: PeerIdentity

  LeaseRow* = object
    id*: LeaseId
    sessionId*: SessionId
    label*: string
    resources*: ResourceVector
    state*: LeaseLifecycleState
    supervisorProcessId*: uint64
    supervisorUserId*: uint64
    peer*: PeerIdentity
    childProcessId*: uint64
    processGroupId*: uint64
    cleanupRegistered*: bool
    finishOutcome*: LeaseFinishOutcome
    finishDiagnostic*: Diagnostic

  ConnectionContext* = object
    supervisorProcessId*: uint64
    supervisorUserId*: uint64
    peer*: PeerIdentity
    sessionIds*: seq[SessionId]

  RunQuotaDaemon* = object
    config*: DaemonConfig
    state*: DaemonState
    nextSessionId*: uint64
    nextLeaseId*: uint64
    totalGranted*: uint64
    totalFinished*: uint64
    sessions*: Table[uint64, SessionRow]
    leases*: Table[uint64, LeaseRow]
