## The one-line account of a host-configuration reload: what `runquotad`
## logs when it reloads, and what `runquota config` prints from the daemon's
## `HostConfigReloaded` answer. One proc, so the log and the CLI say the same
## thing about the same reload.

import std/strutils

import runquota_protocol
import ./host_config

proc reloadReport*(answer: HostConfigReloadedMessage): string =
  ## The one line `runquotad` logs for a reload, and the summary
  ## `runquota config` prints.
  result = "memory_bytes = " & $answer.memoryBytes & " (" &
    humanBytes(answer.memoryBytes) & "), cpu_milli = " & $answer.cpuMilli
  if answer.pools.len > 0:
    var parts: seq[string] = @[]
    for pool in answer.pools:
      parts.add(pool.name & "=" & $pool.units)
    result.add(", pools " & parts.join(" "))
  result.add("; from " & (if answer.sourcePath.len > 0: answer.sourcePath
    else: "the built-in defaults (no " & answer.configPath & ")"))
  if answer.pinnedByFlags.len > 0:
    result.add("; pinned by runquotad flags, so the file's value is not " &
      "in force: " & answer.pinnedByFlags.join(", "))
  result.add("; " & $answer.promotedLeases & " queued lease(s) granted")
  if answer.memoryInUse > answer.memoryBytes or
      answer.cpuInUse > answer.cpuMilli:
    result.add("; granted leases hold " & humanBytes(answer.memoryInUse) &
      " / " & $answer.cpuInUse & " milli-CPU, over the new budget: they " &
      "keep running, and nothing new is admitted until they finish")
