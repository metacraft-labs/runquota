import std/os
import std/[strutils, tables]

import runquota_core
import runquota_daemon
import runquota_ipc

proc parseCpuShareGroupSpec(config: var DaemonConfig; spec: string): bool =
  let parts = spec.split("=", 1)
  if parts.len != 2 or parts[0].len == 0:
    return false
  config.cpuShareGroups[parts[0]] = cpuShareGroup(parts[0], milliCpu(parseUInt(
      parts[1])))
  true

proc parseMachineSpec(config: var DaemonConfig; spec: string): bool =
  let parts = spec.split("=", 1)
  if parts.len != 2 or parts[0].len == 0:
    return false
  let fields = parts[1].split(",")
  if fields.len < 2 or fields.len > 4:
    return false
  let ioSlots =
    if fields.len >= 3 and fields[2].len > 0:
      uint32(parseUInt(fields[2]))
    else:
      config.ioSlots
  let group =
    if fields.len >= 4 and fields[3].len > 0:
      fields[3]
    else:
      parts[0]
  config.machines[parts[0]] = machineCapacity(
    parts[0],
    milliCpu(parseUInt(fields[0])),
    bytes(parseUInt(fields[1])),
    ioSlots,
    group
  )
  true

when isMainModule:
  let args = commandLineParams()
  if args.len == 1 and args[0] in ["--version", "-V"]:
    echo "runquotad " & versionString()
    quit 0

  var config = defaultDaemonConfig(defaultEndpoint())
  let usage = "usage: runquotad [--socket PATH] [--cpu-milli N] [--memory-bytes N] [--io-slots N] [--machine ID=CPU_MILLI,MEMORY_BYTES[,IO_SLOTS[,CPU_SHARE_GROUP]]] [--cpu-share-group ID=CPU_MILLI] [--pool NAME=UNITS] [--memory-pressure-source host|deterministic-file|unavailable] [--memory-pressure-file PATH] [--memory-pressure-required] [--memory-pressure-heavy-bytes N] [--estimate-db PATH]"
  var i = 0
  while i < args.len:
    case args[i]
    of "--socket":
      if i + 1 >= args.len:
        echo usage
        quit 2
      # Resolve the path to an endpoint: a Unix-domain socket on POSIX, a
      # named pipe on Windows. A `\\.\pipe\...` value is used as-is; any other
      # path (e.g. a `.sock` path from a cross-platform caller) is mapped
      # deterministically onto a named pipe so the matching client agrees.
      config.endpoint = endpointForPath(args[i + 1])
      i += 2
    of "--cpu-milli":
      if i + 1 >= args.len:
        quit 2
      config.cpuSlots = milliCpu(parseUInt(args[i + 1]))
      i += 2
    of "--memory-bytes":
      if i + 1 >= args.len:
        quit 2
      config.memoryBytes = bytes(parseUInt(args[i + 1]))
      i += 2
    of "--io-slots":
      if i + 1 >= args.len:
        quit 2
      config.ioSlots = uint32(parseUInt(args[i + 1]))
      i += 2
    of "--machine":
      if i + 1 >= args.len or not config.parseMachineSpec(args[i + 1]):
        echo usage
        quit 2
      i += 2
    of "--cpu-share-group":
      if i + 1 >= args.len or not config.parseCpuShareGroupSpec(args[i + 1]):
        echo usage
        quit 2
      i += 2
    of "--pool":
      if i + 1 >= args.len:
        quit 2
      let parts = args[i + 1].split("=", 1)
      if parts.len != 2:
        quit 2
      config.namedPoolCaps[parts[0]] = uint32(parseUInt(parts[1]))
      i += 2
    of "--memory-pressure-source":
      if i + 1 >= args.len:
        quit 2
      case args[i + 1]
      of "host":
        config.pressureSource = pressureSourceHost
      of "deterministic-file":
        config.pressureSource = pressureSourceDeterministicFile
      of "unavailable":
        config.pressureSource = pressureSourceUnavailable
      else:
        echo "unknown memory pressure source: " & args[i + 1]
        quit 2
      i += 2
    of "--memory-pressure-file":
      if i + 1 >= args.len:
        quit 2
      config.pressureFile = args[i + 1]
      i += 2
    of "--memory-pressure-required":
      config.pressureRequired = true
      i += 1
    of "--memory-pressure-heavy-bytes":
      if i + 1 >= args.len:
        quit 2
      config.memoryPressureHeavyBytes = bytes(parseUInt(args[i + 1]))
      i += 2
    of "--estimate-db":
      if i + 1 >= args.len:
        quit 2
      config.estimateDbPath = args[i + 1]
      i += 2
    of "--help", "-h":
      echo "runquotad " & versionString() & "\n" & usage
      quit 0
    else:
      echo "unknown runquotad argument: " & args[i]
      quit 2

  quit serve(config)
