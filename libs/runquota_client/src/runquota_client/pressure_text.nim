## Build-wait pressure as a person reads it: the daemon's `PressureAnswer`
## JSON rendered as text. Shared by `runquota pressure` and by other
## clients' own commands (Reprobuild's `repro pressure`), so both print the
## same thing.

import std/[json, strutils]

proc fixed(value: float64; digits = 2): string =
  formatFloat(value, ffDecimal, digits)

proc secondsOf(micros: BiggestInt): string =
  fixed(float64(micros) / 1e6, 1) & " s"

proc averageLine(node: JsonNode): string =
  "avg10=" & fixed(node{"avg10"}.getFloat) &
    " avg60=" & fixed(node{"avg60"}.getFloat) &
    " avg300=" & fixed(node{"avg300"}.getFloat) &
    " total=" & secondsOf(node{"total_micros"}.getBiggestInt)

proc scopeLines(title: string; node: JsonNode): seq[string] =
  let wall = node{"wall_micros"}.getBiggestInt
  let some = node{"some"}{"total_micros"}.getBiggestInt
  var share = ""
  if wall > 0:
    share = " (" & fixed(100.0 * float64(some) / float64(wall), 1) &
      "% of reported wall time)"
  result.add(title & ": " & $node{"reports"}.getBiggestInt & " reports over " &
    secondsOf(wall) & share)
  if node{"queue_only_reports"}.getBiggestInt > 0:
    result.add("  queue only: " & $node{"queue_only_reports"}.getBiggestInt &
      " reports had no expected duration, so they count queue waits only")
  result.add("  some  " & averageLine(node{"some"}))
  result.add("  full  " & averageLine(node{"full"}))
  var waits: seq[string]
  for kind, figures in node{"waits"}.pairs:
    let count = figures{"count"}.getBiggestInt
    if count == 0:
      continue
    waits.add(kind & " " & $count & " (" &
      fixed(float64(figures{"sum_millis"}.getBiggestInt) / 1000.0, 1) &
      " s, " & $figures{"long_waits"}.getBiggestInt & " long)")
  result.add("  waits of 1 s or more: " &
    (if waits.len == 0: "none" else: waits.join(", ")))

proc renderPressureText*(answer: string): string =
  ## The answer as text: the host, then each group and open session that
  ## has reported. Averages are held-up time per second of wall time
  ## (summed over the invocations of a group or the host); "long" counts
  ## waits at or over the daemon's long-wait threshold. Raises
  ## `JsonParsingError` / `KeyError` on an answer it cannot read.
  let root = parseJson(answer)
  var lines: seq[string]
  lines.add("long-wait threshold: " &
    fixed(float64(root{"long_wait_millis"}.getBiggestInt) / 1000.0, 0) & " s")
  if root.hasKey("host"):
    lines.add(scopeLines("host", root["host"]))
  if root.hasKey("groups"):
    if root["groups"].len == 0:
      lines.add("groups: none has reported")
    for group in root["groups"]:
      let owner =
        if group{"owner_uid"}.kind == JInt: "uid " & $group{"owner_uid"}.getInt
        else: "owner unknown"
      lines.add(scopeLines("group " & group{"name"}.getStr & " (" & owner &
        ")", group))
  if root.hasKey("sessions"):
    for session in root["sessions"]:
      lines.add(scopeLines("session " & $session{"session_id"}.getBiggestInt &
        " " & session{"name"}.getStr & " (group " & session{"group"}.getStr &
        ")", session))
  if root.hasKey("classes"):
    for class in root["classes"]:
      let leaseWaits = class{"lease_waits"}
      var title = "class " & class{"name"}.getStr
      if not class{"configured"}.getBool:
        title.add(" (no reservation)")
      lines.add(scopeLines(title, class))
      if not leaseWaits.isNil:
        lines.add("  leases granted: " & $leaseWaits{"grants"}.getBiggestInt &
          ", queued " & fixed(float64(
            leaseWaits{"wait_total_millis"}.getBiggestInt) / 1000.0, 1) &
          " s in all, longest " & fixed(float64(
            leaseWaits{"wait_max_millis"}.getBiggestInt) / 1000.0, 1) & " s")
  if root{"reports_refused"}.getBiggestInt > 0:
    lines.add("reports refused: " & $root{"reports_refused"}.getBiggestInt)
  lines.join("\n")
