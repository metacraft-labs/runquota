import runquota_cli_support
import runquota_cli_support/run_command

when isMainModule:
  # `exitWithStatus`, not `quit`: `runquota run` reports a killed child as
  # 128 + signal, and Nim's `quit` cannot carry a status above 127.
  exitWithStatus runThinApp("runquota")
