## `runquota profile`, `runquota sizing` and `runquota observations export
## --format sizing`: the sizing surface. The replay they ask for is
## defined step by step in ``runquota_observation_store/sizing_replay``.
##
## OVER THE SOCKET, like `runquota stats`: the daemon is the store's only
## reader, so these verbs send `QuerySizing` and print what comes back.
## `--json` prints the daemon's document unchanged, so the text form and the
## JSON form cannot disagree about a figure: the text is rendered from it.
##
## EXIT CODES ARE `runquota stats`'s: 0 an answer, 3 no answer (no run of
## the project in scope), 4 no instrument (capture off, no daemon), 2 bad
## arguments. A replay computed from incomplete data is still 0, and its
## caveats say what was missing.

import std/[json, strutils]

import runquota_client
import runquota_protocol

type
  SizingOptions* = object
    what*: SizingWhat
    project*: string
    entryPoint*: string
    cpus*: seq[uint32]
    quantilePpm*: uint32
    sinceMillis*: uint64
    allProfiles*: bool
    allUsers*: bool
    json*: bool
    redaction*: SizingRedaction

proc parseDuration*(text: string; millis: var uint64): bool =
  ## `30d`, `12h`, `90m`, `45s` or `1500ms`.
  let lower = text.strip().toLowerAscii()
  var digits = lower
  var factor = 1'u64
  for (suffix, f) in [("ms", 1'u64), ("s", 1000'u64), ("m", 60_000'u64),
                      ("h", 3_600_000'u64), ("d", 86_400_000'u64)]:
    if lower.endsWith(suffix):
      digits = lower[0 ..< lower.len - suffix.len]
      factor = f
      break
  if digits.len == 0 or digits == lower:
    return false
  for ch in digits:
    if ch notin {'0' .. '9'}:
      return false
  try:
    let value = parseBiggestUInt(digits).uint64
    if value == 0 or value > high(uint64) div factor:
      return false
    millis = value * factor
    true
  except ValueError:
    false

proc parseSizingOptions*(verb: string; args: seq[string];
                         options: var SizingOptions): string =
  ## "" when ``args`` parse; otherwise the reason they do not.
  options.what =
    case verb
    of "profile": swProfile
    of "sizing": swSizing
    else: swExport
  var i = 0
  proc value(name: string): string =
    if i + 1 >= args.len or args[i + 1].len == 0:
      raise newException(ValueError, name & " needs a value")
    result = args[i + 1]
    i += 2
  try:
    while i < args.len:
      case args[i]
      of "--project": options.project = value("--project")
      of "--entry-point": options.entryPoint = value("--entry-point")
      of "--cpus":
        if verb != "sizing":
          return "--cpus is for 'runquota sizing'"
        for part in value("--cpus").split(','):
          let n =
            try: parseBiggestUInt(part.strip())
            except ValueError: 0'u64
          if n == 0'u64 or n > 1_000_000'u64:
            return "--cpus takes counts from 1 to 1000000 separated by commas"
          options.cpus.add(uint32(n))
        if options.cpus.len > MaxSizingCpuCounts:
          return "--cpus takes at most " & $MaxSizingCpuCounts & " counts"
      of "--quantile":
        let text = value("--quantile")
        let q =
          try: parseFloat(text)
          except ValueError: -1.0
        if not (q > 0.0 and q <= 1.0):
          return "--quantile takes a number in (0, 1], got " & text
        options.quantilePpm = uint32(q * 1_000_000.0 + 0.5)
      of "--since":
        let text = value("--since")
        if not parseDuration(text, options.sinceMillis):
          return "--since takes a duration such as 30d, 12h or 90m, got " & text
      of "--host-profile":
        let text = value("--host-profile")
        case text
        of "current": options.allProfiles = false
        of "all": options.allProfiles = true
        else: return "--host-profile is current or all, got " & text
      of "--all-users":
        options.allUsers = true
        inc i
      of "--json":
        options.json = true
        inc i
      of "--format":
        if verb != "export":
          return "--format is for 'runquota observations export'"
        let text = value("--format")
        if text != "sizing":
          return "--format: only 'sizing' exists"
      of "--redact":
        if verb != "export":
          return "--redact is for 'runquota observations export'"
        let text = value("--redact")
        case text
        of "default": options.redaction = srDefault
        of "strict": options.redaction = srStrict
        of "none": options.redaction = srNone
        else: return "--redact is default, strict or none, got " & text
      else:
        return "unrecognised argument '" & args[i] & "'"
  except ValueError as error:
    return error.msg
  if verb in ["sizing", "export"] and options.project.len == 0:
    return "--project is required"
  if verb == "sizing" and options.cpus.len == 0:
    return "--cpus N[,N...] is required"
  ""

proc statusExit(status: string): int =
  case status
  of "ok": 0
  of "no-runs": 3
  else: 4

proc humanBytes(value: JsonNode): string =
  if value.isNil or value.kind != JInt:
    return "unknown"
  let bytes = value.getBiggestInt()
  let gib = float64(bytes) / (1024.0 * 1024.0 * 1024.0)
  if gib >= 1.0: formatFloat(gib, ffDecimal, 2) & " GiB"
  else: formatFloat(float64(bytes) / (1024.0 * 1024.0), ffDecimal, 1) & " MiB"

proc renderSizingText*(answer: JsonNode): string =
  ## The text form of `runquota sizing`, rendered from the JSON answer.
  result = "status: " & answer{"status"}.getStr() &
    "  project: " & answer{"project"}.getStr() &
    "  quantile: " & $answer{"quantile"}.getFloat() &
    "  host profile: " & answer{"host_profile"}.getStr() & "\n"
  let runs = answer{"runs"}
  result.add("runs: " & $runs{"replayed"}.getInt() & " replayed of " &
    $runs{"candidates"}.getInt() & " (incomplete " & $runs{"incomplete"}.getInt() &
    ", open " & $runs{"open"}.getInt() & ", empty " & $runs{"empty"}.getInt() &
    ", other profile " & $(runs{"other_profile"}.getInt() +
      runs{"mixed_profiles"}.getInt()) & ")\n")
  let baseline = answer{"baseline"}
  result.add("baseline (foreign RSS): " &
    (if baseline{"known"}.getBool(): humanBytes(baseline{"quantile_bytes"}) &
       " at the quantile, " & humanBytes(baseline{"max_bytes"}) & " max, " &
       $baseline{"samples"}.getInt() & " samples"
     else: "unknown") & "\n")
  for size in answer{"sizes"}.getElems():
    result.add("  N=" & $size{"cpus"}.getInt() & ": memory " &
      humanBytes(size{"memory_quantile_bytes"}) & " (max " &
      humanBytes(size{"memory_max_bytes"}) & "), with baseline " &
      humanBytes(size{"total_bytes"}) & ", makespan " &
      $size{"makespan_quantile_millis"}.getBiggestInt() & " ms\n")
  for caveat in answer{"caveats"}.getElems():
    result.add("note: " & caveat.getStr() & "\n")
  result.stripLineEnd()

proc renderProfileText*(answer: JsonNode): string =
  result = "status: " & answer{"status"}.getStr() & "  quantile: " &
    $answer{"quantile"}.getFloat() & "\n"
  for p in answer{"profiles"}.getElems():
    let project = if p{"project"}.kind == JNull: "(none)" else: p{"project"}.getStr()
    let entry =
      if p{"entry_point"}.kind == JNull: "(none)" else: p{"entry_point"}.getStr()
    result.add(project & " / " & entry & " on " & p{"host_profile"}.getStr() &
      ": " & $p{"runs"}.getInt() & " runs, " & $p{"executions"}.getInt() &
      " executions; peak memory " & humanBytes(p{"peak_memory_bytes"}{"quantile"}) &
      " (max " & humanBytes(p{"peak_memory_bytes"}{"max"}) & "), duration " &
      $p{"duration_millis"}{"quantile"}.getBiggestInt() & " ms, write " &
      $p{"write_bytes_per_sec"}{"quantile"}.getBiggestInt() & " B/s\n")
  for caveat in answer{"caveats"}.getElems():
    result.add("note: " & caveat.getStr() & "\n")
  result.stripLineEnd()

proc runSizingVerb*(verb: string; args: seq[string]): int =
  ## `runquota profile|sizing ...` and `runquota observations export ...`.
  var options = SizingOptions()
  let problem = parseSizingOptions(verb, args, options)
  let name = if verb == "export": "observations export" else: verb
  if problem.len > 0:
    stderr.writeLine("runquota " & name & ": " & problem)
    return 2
  var query = QuerySizingMessage(what: options.what, project: options.project,
    entryPoint: options.entryPoint, cpus: options.cpus,
    quantilePpm: options.quantilePpm, sinceMillis: options.sinceMillis,
    allProfiles: options.allProfiles, allUsers: options.allUsers,
    redaction: options.redaction, offset: 0)
  var client: RunQuotaClient
  try:
    client = connectDefault()
  except CatchableError as error:
    stderr.writeLine("runquota " & name & ": daemon-unreachable: " & error.msg)
    return 4
  defer: client.close()
  try:
    if options.what == swExport:
      # NDJSON ON STDOUT, THE STATUS ON STDERR, as `stats export` does, so
      # the output pipes into a replay or `jq` unchanged.
      var status = "ok"
      while true:
        let page = parseJson(client.querySizing(query))
        status = page{"status"}.getStr()
        for line in page{"lines"}.getElems():
          stdout.writeLine(line.getStr())
        let next = page{"next"}
        if next.isNil or next.kind != JInt:
          break
        query.offset = uint32(next.getInt())
      stderr.writeLine("runquota observations export: " & status)
      return statusExit(status)
    let text = client.querySizing(query)
    let answer = parseJson(text)
    if options.json:
      echo text
    elif options.what == swSizing:
      echo renderSizingText(answer)
    else:
      echo renderProfileText(answer)
    statusExit(answer{"status"}.getStr())
  except CatchableError as error:
    stderr.writeLine("runquota " & name & ": " & error.msg)
    1
