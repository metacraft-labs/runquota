import std/tables

import runquota_core
import runquota_ipc
import runquota_persistence
import runquota_protocol

type
  LibraryInfo* = object
    name*: string

  DaemonState* = enum
    dsStarting
    dsServing
    dsStopping

  LeaseLifecycleState* = enum
    leaseStateQueued
    leaseStateGranted
    leaseStateStarting
    leaseStateRunning
    leaseStateFinished
    leaseStateSupervisorLost

  PressureSourceKind* = enum
    pressureSourceHost
    pressureSourceDeterministicFile
    pressureSourceUnavailable

  DaemonConfig* = object
    endpoint*: Endpoint
    daemonId*: uint64
    cpuSlots*: MilliCpu
    memoryBytes*: Bytes
    ioSlots*: uint32
    namedPoolCaps*: Table[string, uint32]
    version*: string
    pressureSource*: PressureSourceKind
    pressureFile*: string
    pressureRequired*: bool
    memoryPressureHeavyBytes*: Bytes
    estimateDbPath*: string
    estimateQueueCapacity*: int

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
    commandStatsId*: string
    clientCandidateId*: uint64
    resources*: ResourceVector
    priority*: PriorityClass
    queueOrder*: uint64
    delivered*: bool
    state*: LeaseLifecycleState
    supervisorProcessId*: uint64
    supervisorUserId*: uint64
    peer*: PeerIdentity
    childProcessId*: uint64
    processGroupId*: uint64
    cleanupRegistered*: bool
    finishOutcome*: LeaseFinishOutcome
    finishDiagnostic*: Diagnostic
    peakMemoryBytes*: uint64
    processCount*: uint32
    majorPageFaults*: uint64
    pressureEvents*: uint32
    hardLimitOrOom*: bool
    queueDiagnostic*: Diagnostic

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
    nextQueueOrder*: uint64
    lastGrantedSessionId*: uint64
    totalGranted*: uint64
    totalFinished*: uint64
    sessions*: Table[uint64, SessionRow]
    leases*: Table[uint64, LeaseRow]
    estimates*: Table[string, LearnedEstimateRow]
    estimateStore*: EstimateStore
