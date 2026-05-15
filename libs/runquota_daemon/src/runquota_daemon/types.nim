import std/tables

import runquota_core
import runquota_ipc

type
  LibraryInfo* = object
    name*: string

  DaemonState* = enum
    dsStarting
    dsServing
    dsStopping

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

  LeaseRow* = object
    id*: LeaseId
    sessionId*: SessionId
    label*: string
    resources*: ResourceVector

  RunQuotaDaemon* = object
    config*: DaemonConfig
    state*: DaemonState
    nextSessionId*: uint64
    nextLeaseId*: uint64
    totalGranted*: uint64
    sessions*: Table[uint64, SessionRow]
    leases*: Table[uint64, LeaseRow]
