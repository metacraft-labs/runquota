import std/os
import std/[strutils, tables]

import runquota_core
import runquota_daemon
import runquota_ipc

when isMainModule:
  let args = commandLineParams()
  if args.len == 1 and args[0] in ["--version", "-V"]:
    echo "runquotad " & versionString()
    quit 0

  var config = defaultDaemonConfig(defaultEndpoint())
  let usage = "usage: runquotad [--socket PATH] [--cpu-milli N] [--memory-bytes N] [--io-slots N] [--pool NAME=UNITS] [--memory-pressure-source host|deterministic-file|unavailable] [--memory-pressure-file PATH] [--memory-pressure-required] [--memory-pressure-heavy-bytes N] [--estimate-db PATH]"
  var i = 0
  while i < args.len:
    case args[i]
    of "--socket":
      if i + 1 >= args.len:
        echo usage
        quit 2
      config.endpoint = unixEndpoint(args[i + 1])
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
