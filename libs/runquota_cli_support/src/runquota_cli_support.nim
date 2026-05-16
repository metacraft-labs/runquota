import std/[os, osproc, strutils]

import runquota_client
import runquota_core
import runquota_protocol

proc wantsVersion*(args: openArray[string]): bool =
  args.len == 1 and args[0] in ["--version", "-V"]

proc renderVersion*(programName: string): string =
  programName & " " & versionString()

proc renderUsage*(programName: string): string =
  programName & " " & versionString() & "\n" &
    "usage:\n" &
    "  " & programName & " --version\n" &
    "  " & programName & " status [--json]\n" &
    "  " & programName & " daemon start|status\n" &
    "  " & programName & " acquire --cpu N --mem BYTES [--label TEXT]"

proc parseMemory(value: string): uint64 =
  let lower = value.toLowerAscii()
  if lower.endsWith("gib"):
    return parseUInt(lower[0 ..< lower.len - 3]) * 1024'u64 * 1024'u64 * 1024'u64
  if lower.endsWith("mib"):
    return parseUInt(lower[0 ..< lower.len - 3]) * 1024'u64 * 1024'u64
  if lower.endsWith("kib"):
    return parseUInt(lower[0 ..< lower.len - 3]) * 1024'u64
  if lower.endsWith("gb"):
    return parseUInt(lower[0 ..< lower.len - 2]) * 1000'u64 * 1000'u64 * 1000'u64
  if lower.endsWith("mb"):
    return parseUInt(lower[0 ..< lower.len - 2]) * 1000'u64 * 1000'u64
  if lower.endsWith("kb"):
    return parseUInt(lower[0 ..< lower.len - 2]) * 1000'u64
  parseUInt(lower)

proc printStatus(json: bool): int =
  var client = connectDefault()
  defer: client.close()
  let status = client.daemonStatus()
  if json:
    echo inspectionStatusJson(status)
  else:
    echo "sessions: " & $status.activeSessions
    echo "leases: " & $status.activeLeases
    echo "supervisor_lost_leases: " & $status.supervisorLostLeases
    echo "finished_leases: " & $status.finishedLeases
    echo "total_granted: " & $status.totalGranted
    echo "total_finished: " & $status.totalFinished
  0

proc daemonProgramPath*(): string =
  let sibling = getAppDir() / "runquotad"
  if fileExists(sibling):
    sibling
  else:
    "runquotad"

proc runDaemonStart(): int =
  try:
    discard printStatus(false)
    return 0
  except CatchableError:
    discard
  let process = startProcess(
    daemonProgramPath(),
    args = [],
    options = {poUsePath, poDaemon, poParentStreams}
  )
  process.close()
  for _ in 0 ..< 40:
    try:
      discard printStatus(false)
      return 0
    except CatchableError:
      sleep(50)
  echo "runquotad did not become ready"
  1

proc runDebugAcquire(args: seq[string]): int =
  var cpu = 1000'u32
  var memory = 128'u64 * 1024'u64 * 1024'u64
  var label = "debug"
  var i = 0
  while i < args.len:
    case args[i]
    of "--cpu":
      if i + 1 >= args.len: return 2
      cpu = uint32(parseUInt(args[i + 1]))
      i += 2
    of "--mem":
      if i + 1 >= args.len: return 2
      memory = parseMemory(args[i + 1])
      i += 2
    of "--label":
      if i + 1 >= args.len: return 2
      label = args[i + 1]
      i += 2
    of "--":
      echo "process execution starts in a later RunQuota milestone"
      return 2
    else:
      echo "unknown acquire argument: " & args[i]
      return 2
  var client = connectDefault()
  defer: client.close()
  var session = client.registerSession("runquota acquire", versionString())
  var request = resourceRequest(label, milliCpu(cpu), bytes(memory))
  var lease = session.requestLease(request)
  echo "lease " & $lease.id & " granted"
  lease.release()
  session.closeSession()
  echo "lease " & $lease.id & " released"
  0

proc runThinApp*(programName: string): int =
  let args = commandLineParams()
  if wantsVersion(args):
    echo renderVersion(programName)
    return 0
  if args.len >= 1:
    try:
      case args[0]
      of "status":
        return printStatus(args.len == 2 and args[1] == "--json")
      of "daemon":
        if args.len == 2 and args[1] == "start":
          return runDaemonStart()
        if args.len == 2 and args[1] == "status":
          return printStatus(false)
      of "acquire":
        return runDebugAcquire(args[1 .. ^1])
      else:
        discard
    except CatchableError as error:
      echo error.msg
      return 1
  echo renderUsage(programName)
  0
