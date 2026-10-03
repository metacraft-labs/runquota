## `runquota config`: read, change and reload the host budget file.
##
## The file is `hostConfigPath` (`C:\ProgramData\runquota\runquotad.toml`,
## `/etc/runquota/runquotad.toml`); its shape and precedence are
## `reprobuild-specs/RunQuota-Host-Configuration.md`. This is the verb that
## spec's "Writing it" names, beside the installers and the operator's editor.
##
## THREE RULES, and each is somebody else's code doing the checking:
##
## * AN EDIT IS VALIDATED BY THE DAEMON'S OWN READER before it is written
##   (`editHostConfig` runs `parseHostConfig` over the edited text), so this
##   verb cannot write a file the daemon would refuse to start on.
## * THE WRITE IS ATOMIC AND NEVER CREATES THE DIRECTORY
##   (`writeHostConfigAtomically`). The directory's owner and ACL are the
##   install step's to decide; on a host where it is missing the verb says
##   so and writes nothing.
## * A CHANGE IS PUT IN FORCE BY ASKING THE RUNNING DAEMON TO RELOAD
##   (`ReloadHostConfig`), the same request `runquota config reload` sends.
##   The daemon then re-reads the file itself; nothing here tells it a value.

import std/[cpuinfo, json, options, os, strutils, tables]

import runquota_client
import runquota_core
from runquota_ipc import defaultEndpoint
import runquota_daemon/host_config
import runquota_daemon/host_memory
import runquota_daemon/reload_report

const configUsage* =
  "  runquota config path\n" &
  "  runquota config show [--file PATH]\n" &
  "  runquota config set KEY VALUE [--file PATH] [--no-reload]\n" &
  "  runquota config unset KEY [--file PATH] [--no-reload]\n" &
  "  runquota config reload\n" &
  "    KEY is machine.memory_bytes (VALUE may be 96GiB, 512MiB, 64GB, ...),\n" &
  "    machine.cpu_milli or pools.NAME. set/unset check the edit with the\n" &
  "    daemon's own reader, write the file atomically, and ask the running\n" &
  "    daemon to reload it; reload asks it to re-read a file edited by hand.\n"

type
  ConfigOptions = object
    verb: string
    key: string
    value: string
    file: string
    reload: bool

proc parseConfigOptions(args: seq[string]; options: var ConfigOptions): bool =
  if args.len == 0:
    return false
  options = ConfigOptions(verb: args[0], file: hostConfigPath, reload: true)
  var positional: seq[string] = @[]
  var i = 1
  while i < args.len:
    case args[i]
    of "--file":
      if i + 1 >= args.len: return false
      options.file = args[i + 1]
      i += 2
    of "--no-reload":
      options.reload = false
      i += 1
    else:
      if args[i].startsWith("--"): return false
      positional.add(args[i])
      i += 1
  case options.verb
  of "path", "show", "reload":
    positional.len == 0
  of "set":
    if positional.len != 2: return false
    options.key = positional[0]
    options.value = positional[1]
    true
  of "unset":
    if positional.len != 1: return false
    options.key = positional[0]
    true
  else:
    false

proc builtinCpuMilli(): uint64 =
  uint64(max(1, countProcessors())) * 1000'u64

proc describeValue(value: uint64; memory: bool): string =
  if memory: $value & " (" & humanBytes(value) & ")" else: $value

proc showFile(path: string): int =
  echo "host configuration: " & path
  var host: HostConfig
  try:
    host = readHostConfig(path)
  except HostConfigError as err:
    echo "  " & err.msg
    echo "  a daemon will refuse to start on this file; a reload keeps " &
      "the budget it has"
    return 1
  let physical = hostPhysicalMemoryBytes()
  let defaultMemory = defaultMemoryBudgetBytes(physical)
  if host.sourcePath.len == 0:
    echo "  (no file: every key is its built-in default)"
  echo "  machine.memory_bytes = " & (
    if host.memoryBytes.isSome: describeValue(host.memoryBytes.get, true)
    else: "unset -> default " & describeValue(defaultMemory, true) & ", " &
      (if physical > 0: $DefaultMemoryBudgetPercent & "% of " &
        humanBytes(physical) & " physical memory"
       else: "physical memory unreadable"))
  echo "  machine.cpu_milli    = " & (
    if host.cpuMilli.isSome: $host.cpuMilli.get
    else: "unset -> default " & $builtinCpuMilli() & " (" &
      $max(1, countProcessors()) & " logical processors)")
  for name, units in host.pools:
    echo "  pools." & name & " = " & $units
  0

proc showDaemon(): int =
  ## The budget IN FORCE, which is the daemon's answer and not the file's:
  ## a flag can pin a key, and a file edited without a reload is not read
  ## yet. Read from the `topology` inspection subject, whose `host_config`
  ## object names the file and what the flags pin.
  if not daemonReachable(defaultEndpoint()):
    echo "in force: no runquotad answers at " & defaultEndpoint().path &
      "; the next one to start reads the file above"
    return 0
  try:
    var client = connectDefault()
    defer: client.close()
    let topology = parseJson(client.inspectionJson("topology"))
    for machine in topology["machines"]:
      if machine["id"].getStr == DefaultMachineId:
        echo "in force (runquotad at " & defaultEndpoint().path & "):"
        echo "  memory_bytes = " & describeValue(
          uint64(machine["memory_bytes"].getBiggestInt), true)
        echo "  cpu_milli    = " & $machine["cpu_milli"].getBiggestInt
    if topology.hasKey("pools"):
      for pool in topology["pools"]:
        # Where the cap comes from: a flag, the file, or -- for a pool
        # neither names -- the smallest capacity an open session declared.
        let source = pool{"source"}.getStr
        echo "  pools." & pool["name"].getStr & " = " &
          $pool["units"].getInt & (case source
            of "flag": " (pinned by a runquotad flag)"
            of "host-file": " (host file)"
            of "declared": " (declared by open sessions; the host file " &
              "overrides it)"
            else: "")
    if topology.hasKey("host_config"):
      let hostConfig = topology["host_config"]
      let source = hostConfig["source"].getStr
      echo "  read from: " & (if source.len > 0: source
        else: "no file (" & hostConfig["path"].getStr & " did not exist)")
      var pinned: seq[string] = @[]
      for key in hostConfig["pinned_by_flags"]:
        pinned.add(key.getStr)
      if pinned.len > 0:
        echo "  pinned by runquotad flags (the file's value is not in " &
          "force): " & pinned.join(", ")
    else:
      echo "  (this runquotad predates host-configuration reload)"
  except CatchableError as err:
    echo "in force: could not ask runquotad: " & err.msg
    return 1
  0

proc reloadDaemon(writtenPath: string): int =
  ## Ask the running daemon to re-read its file. 0 when it did, or when no
  ## daemon runs (the next one reads the file at start); 1 when it refused.
  if not daemonReachable(defaultEndpoint()):
    # A daemon on a PRIVATE endpoint is not this one: reprobuild starts one
    # per build on an unprovisioned Linux or macOS host, and it is reached
    # only with that build's RUNQUOTA_SOCKET. Said here, where the operator
    # would otherwise conclude no daemon runs at all.
    echo "no runquotad answers at " & defaultEndpoint().path &
      "; the next one to start reads " &
      (if writtenPath.len > 0: writtenPath else: "its host file") &
      " (a daemon on a private endpoint, such as one reprobuild started " &
      "for a single build, is reached with RUNQUOTA_SOCKET set to its socket)"
    return 0
  try:
    var client = connectDefault()
    defer: client.close()
    let answer = client.reloadHostConfig()
    echo "runquotad reloaded its host configuration: " & reloadReport(answer)
    if writtenPath.len > 0 and
        normalizedPath(answer.configPath) != normalizedPath(writtenPath):
      echo "note: that daemon reads " & answer.configPath & ", not " &
        writtenPath & ", so the file written here is not in force"
    0
  except CatchableError as err:
    echo "runquotad did not reload: " & err.msg
    1

proc runConfig*(args: seq[string]): int =
  var options: ConfigOptions
  if not parseConfigOptions(args, options):
    stderr.writeLine("unrecognised 'config' invocation\nusage:\n" &
      configUsage)
    return 2
  case options.verb
  of "path":
    echo options.file
    0
  of "show":
    let fileStatus = showFile(options.file)
    let daemonStatus = showDaemon()
    max(fileStatus, daemonStatus)
  of "reload":
    reloadDaemon("")
  else:
    var changed = false
    var text: string
    try:
      text = editHostConfig(options.file, options.key, options.value,
        unset = options.verb == "unset", changed)
    except HostConfigError as err:
      echo "runquota config " & options.verb & ": " & err.msg
      return 1
    except IOError as err:
      echo "runquota config " & options.verb & ": cannot read " &
        options.file & ": " & err.msg
      return 1
    if not changed:
      echo options.file & " already " & (if options.verb == "unset":
        "leaves " & options.key & " unset" else: "has " & options.key &
        " = " & options.value) & "; nothing written"
    else:
      try:
        writeHostConfigAtomically(options.file, text)
      except HostConfigError as err:
        echo "runquota config " & options.verb & ": " & err.msg
        return 1
      echo "wrote " & options.file
    if options.reload and changed:
      reloadDaemon(options.file)
    else:
      0
