import std/os

import runquota_core
import runquota_daemon
import runquota_ipc

when isMainModule:
  let args = commandLineParams()
  if args.len == 1 and args[0] in ["--version", "-V"]:
    echo "runquotad " & versionString()
    quit 0

  var endpoint = defaultEndpoint()
  var i = 0
  while i < args.len:
    case args[i]
    of "--socket":
      if i + 1 >= args.len:
        echo "usage: runquotad [--socket PATH]"
        quit 2
      endpoint = unixEndpoint(args[i + 1])
      i += 2
    of "--help", "-h":
      echo "runquotad " & versionString() & "\nusage: runquotad [--socket PATH]"
      quit 0
    else:
      echo "unknown runquotad argument: " & args[i]
      quit 2

  quit serve(defaultDaemonConfig(endpoint))
