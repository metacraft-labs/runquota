## `runquota expect-growth <command-id> [--to SIZE|--reset] [--json]`: declare
## that a command's memory is expected to grow, clear that declaration, or
## show the command's memory-cap figures.
##
## WHY A COMMAND AND NOT A FLAG ON A RUN. A cap is the factor times the
## largest successful peak, so a command whose memory legitimately grows is
## killed by its own history until a run succeeds above the old cap. The
## per-run form (`RUNQUOTA_MEMORY_CAP=off|<size>`) lifts it once; this is the
## persistent, auditable form: the daemon records the declared cap with the
## uid that declared it (from peer credentials) and the time, and every later
## grant of that command id carries a cap of at least that size, whichever
## launcher asks. With neither option nothing changes and the figures are
## printed.
##
## Exit status: 0 when the daemon answered, 1 when it could not be reached,
## predates memory caps or refused the request, 2 on bad arguments.

import std/[json, strutils, times]

import runquota_client
import runquota_core
import runquota_core/byte_sizes
import runquota_protocol

const ExpectGrowthUsage* =
  "  runquota expect-growth COMMAND_ID [--to SIZE|--reset] [--json]\n" &
  "    declare that a command's memory is expected to grow: its next grants\n" &
  "    carry a memory cap of at least SIZE (bytes, or with a K, M, G or T\n" &
  "    binary suffix; at least 1M). --reset removes the declaration; with\n" &
  "    neither, prints the command's cap figures and changes nothing\n" &
  "    (exit 1 when the daemon refuses or cannot be reached, 2 on bad\n" &
  "    arguments). RUNQUOTA_MEMORY_CAP=off|SIZE is the one-run form\n"

type
  ExpectGrowthOptions* = object
    commandId*: string
    action*: ExpectGrowthAction
    sizeBytes*: uint64
    json*: bool

proc parseExpectGrowthArgs*(args: openArray[string];
                            options: var ExpectGrowthOptions;
                            error: var string): bool =
  ## The command line, checked before anything is asked of the daemon. The
  ## size floor and the id's length are the daemon's to enforce too (it is
  ## the authority over what is recorded); refusing them here only saves a
  ## round trip and says it in the same words.
  options = ExpectGrowthOptions(action: egQuery)
  var i = 0
  var sawTo = false
  var sawReset = false
  while i < args.len:
    case args[i]
    of "--to":
      if i + 1 >= args.len:
        error = "--to needs a size"
        return false
      if not parseByteSize(args[i + 1], options.sizeBytes):
        error = "--to takes a size in bytes, or with a K, M, G or T binary " &
          "suffix, got `" & args[i + 1] & "`"
        return false
      sawTo = true
      i += 2
    of "--reset":
      sawReset = true
      i += 1
    of "--json":
      options.json = true
      i += 1
    else:
      if args[i].startsWith("--"):
        error = "unknown expect-growth argument: " & args[i]
        return false
      if options.commandId.len > 0:
        error = "expect-growth takes one command id, got a second: " & args[i]
        return false
      options.commandId = args[i]
      i += 1
  if options.commandId.len == 0:
    error = "expect-growth needs a command id"
    return false
  if options.commandId.len > MaxCommandStatsIdBytes:
    error = "a command id is at most " & $MaxCommandStatsIdBytes &
      " bytes, got " & $options.commandId.len
    return false
  if sawTo and sawReset:
    error = "--to and --reset cannot be combined"
    return false
  if sawTo:
    if options.sizeBytes < MinDeclaredMemoryCapBytes:
      error = "a declared memory cap must be at least 1 MiB, got " &
        $options.sizeBytes & " bytes"
      return false
    options.action = egSet
  elif sawReset:
    options.action = egReset
  true

proc factorText(factorMilli: uint32): string =
  formatFloat(float64(factorMilli) / 1000.0, ffDecimal, 3).strip(
    leading = false, chars = {'0'}).strip(leading = false, chars = {'.'})

proc timeText(unixMillis: uint64): string =
  if unixMillis == 0'u64:
    return "unknown time"
  fromUnix(int64(unixMillis div 1000'u64)).utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

proc renderGrowthText*(commandId: string;
                       answer: GrowthExpectationMessage): string =
  ## The figures as a person reads them.
  result = "command id: " & commandId & "\n"
  if not answer.found:
    result.add("no memory figures are recorded for this command yet\n")
  result.add("largest successful peak: " &
    (if answer.maxObservedPeakBytes > 0'u64:
      formatBinaryBytes(answer.maxObservedPeakBytes)
     else: "none recorded") & "\n")
  result.add("declared cap: " &
    (if answer.declaredCapBytes > 0'u64:
      formatBinaryBytes(answer.declaredCapBytes) & ", declared by uid " &
        $answer.declaredByUid & " at " & timeText(answer.declaredUnixMillis)
     else: "none") & "\n")
  result.add("last breach: " &
    (if answer.lastBreachUnixMillis > 0'u64:
      "cap " & formatBinaryBytes(answer.lastBreachCapBytes) & ", peak " &
        formatBinaryBytes(answer.lastBreachPeakBytes) & " at " &
        timeText(answer.lastBreachUnixMillis)
     else: "none") & "\n")
  result.add("admission figure: " &
    (if answer.conservativeMemoryBytes > 0'u64:
      formatBinaryBytes(answer.conservativeMemoryBytes)
     else: "none learned") & "\n")
  result.add("cap factor: " & factorText(answer.factorMilli) & "\n")

proc renderGrowthJson*(commandId: string;
                       answer: GrowthExpectationMessage): string =
  ## Inspection output only (never read back as state).
  $(%*{
    "command_id": commandId,
    "found": answer.found,
    "max_observed_peak_bytes": answer.maxObservedPeakBytes,
    "declared_cap_bytes": answer.declaredCapBytes,
    "declared_by_uid": answer.declaredByUid,
    "declared_unix_millis": answer.declaredUnixMillis,
    "last_breach_cap_bytes": answer.lastBreachCapBytes,
    "last_breach_peak_bytes": answer.lastBreachPeakBytes,
    "last_breach_unix_millis": answer.lastBreachUnixMillis,
    "conservative_memory_bytes": answer.conservativeMemoryBytes,
    "factor_milli": answer.factorMilli})

proc runExpectGrowth*(args: seq[string];
                      describeFailure: proc(message: string;
                        last: Diagnostic): string): int =
  ## The `expect-growth` verb.
  var options: ExpectGrowthOptions
  var error = ""
  if not parseExpectGrowthArgs(args, options, error):
    stderr.writeLine("runquota expect-growth: " & error)
    return 2
  var client: RunQuotaClient
  var failure: ConnectFailure
  if not tryConnectDefault(client, failure):
    stderr.writeLine("runquota expect-growth: no daemon reached (" &
      failureReason(failure) & "); a declaration is recorded by the daemon")
    return 1
  defer: client.close()
  try:
    let answer = client.expectGrowth(options.commandId, options.action,
      options.sizeBytes)
    if options.json:
      echo renderGrowthJson(options.commandId, answer)
    else:
      stdout.write(renderGrowthText(options.commandId, answer))
    0
  except RunQuotaClientError as refusal:
    stderr.writeLine("runquota expect-growth: " &
      describeFailure(refusal.msg, client.lastDiagnostic))
    1
