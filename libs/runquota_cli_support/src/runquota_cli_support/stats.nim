## `runquota stats` — three verbs over the observation store's read path.
##
## OVER THE SOCKET, ALWAYS. `runquotad` is the only sanctioned reader of
## the store (AGENTS.md, §"Boundaries"), and the inspection gate in
## `tests/unit/t_observation_store_reader_boundary.nim` enforces that for
## every file under `libs/` and `apps/` — including this one. Everything
## below goes through `runquota_client.queryStats`, which is why this
## module does not link the store library and must not.
##
## ---------------------------------------------------------------------
## WHY THERE ARE THREE VERBS AND NOT THIRTEEN
## ---------------------------------------------------------------------
##
## The surface this replaced had a verb per question — rank, rows,
## spread, compare — and every one of them was a guess about what
## somebody would want to know. The next question is always the one that
## is not there, and the usual answers to that are a filter grammar or a
## query language: both of them things a caller has to be TAUGHT, and
## documentation is a cost paid by every agent session that reads it.
##
## `export` avoids the whole category. It emits one JSON object per
## recorded execution, carrying every column the schema holds, and stops.
## Ranking, percentiles, before-and-after, bimodality and every question
## nobody has thought of yet are `jq` expressions over that, written by a
## caller who already knows `jq` and did not have to read anything of
## ours to use it. RunQuota ships facts; the caller does the analysis.
##
## `capture` stays because it is the one thing that is NOT general
## knowledge — whether this host is recording at all — and it is where
## documentation genuinely earns its keep. `top` stays because it answers
## the single most common question in one step and already worked.
##
## ---------------------------------------------------------------------
## AN EMPTY RESULT MUST NEVER LOOK LIKE A HEALTHY ONE
## ---------------------------------------------------------------------
##
## The store's query layer early-returns an empty sequence when capture
## is off, so on a host whose state directory was never provisioned
## "which tests are slowest" answers *nothing* — and nothing reads exactly
## like "no slow tests".
##
## So every verb reports a `status` naming WHICH KIND of nothing it is,
## and the exit code separates the kinds:
##
##   0  `ok`                 rows came back
##   3  `no-data`            capture is on, the store simply has nothing
##      `unknown-key`        capture is on, this key has never been seen
##      `no-rows-in-scope`   rows exist, but not under the filters asked
##   4  `capture-off`        nothing has been recorded and nothing will be
##      `daemon-unreachable` no `runquotad` answered
##      `denied`             the daemon refused to answer, with a reason
##
## Three and four are different on purpose. Three is "the question has no
## answer"; four is "the instrument is not working". A caller that treats
## them alike will conclude from a broken instrument that the system is
## fast.
##
## FOR `export`, THE STATUS GOES TO STDERR AND THE ROWS TO STDOUT. A
## status line mixed into the NDJSON would break the `jq` pipe that is the
## entire point of the verb; an exit code and a stderr line break nothing
## and are visible to both a human and a script. `--json` is there for a
## caller that would rather have one self-describing document than a
## stream.

import std/[strutils, tables]

from runquota_codec import jsonEscape
import runquota_core
import runquota_protocol

type
  StatsVerb* = enum
    svCapture = "capture"
    svTop = "top"
    svExport = "export"

  AnswerStatus* = enum
    asOk = "ok"
    asNoData = "no-data"
    asUnknownKey = "unknown-key"
    asNoRowsInScope = "no-rows-in-scope"
    asCaptureOff = "capture-off"
    asDaemonUnreachable = "daemon-unreachable"
    asDenied = "denied"

  StatsOptions* = object
    verb*: StatsVerb
    statsKey*: string
    limit*: uint32
    allUsers*: bool
    allProfiles*: bool
    json*: bool

  ProfileGroup* = object
    ## `top` only. Rankings are computed per hardware profile and are
    ## never pooled: the same command on a laptop and on a 64-core builder
    ## is not the same measurement, and a CLI that flattened the groups
    ## would undo that at the last possible moment.
    profile*: ProfileIdentityWire
    rankings*: seq[KeyRankingWire]

  StatsAnswerView* = object
    ## THE ONE VALUE EVERY RENDERER CONSUMES, so "the JSON says something
    ## the text does not" is not a bug that can be written.
    verb*: StatsVerb
    statsKey*: string
    status*: AnswerStatus
    captureEnabled*: bool
    scopeApplied*: StatsScopeWire
    spanApplied*: ProfileSpanWire
    ownerUidPresent*: bool
    ownerUid*: uint64
    diagnostic*: Diagnostic
    caveats*: seq[string]
    groups*: seq[ProfileGroup]
    rows*: seq[string]
      ## `export` only: one JSON object per execution, rendered by the
      ## daemon (the only reader that knows the schema's column types) and
      ## carried through here without being parsed. A CLI that re-parsed
      ## them would be a second opinion about their shape.
    probeRowCount*: int

const
  CaptureOffCaveat* =
    "capture is OFF on this daemon: nothing has been recorded and nothing " &
    "will be. This is NOT an empty result — it is an absent instrument."
  RankingSpreadCaveat* =
    "a ranking is total, count and max only, and it SUMS across capture " &
    "grades. For anything else — percentiles, before-and-after, the grade " &
    "of each row — use 'runquota stats export' and jq."
  MultiProfileCaveat* =
    "the profiles below are separate answers and are never combined: the " &
    "same work on different hardware is not the same measurement."
  ExportLimitCaveat* =
    "this is the newest --limit rows and there is no older page: the " &
    "protocol carries a row limit but no time cursor, so a deeper history " &
    "needs a larger --limit, not a second call."

proc exitCode*(status: AnswerStatus): int =
  ## Three means "no answer"; four means "no instrument". A caller that
  ## collapses them concludes from a broken store that the build is fast.
  case status
  of asOk: 0
  of asNoData, asUnknownKey, asNoRowsInScope: 3
  of asCaptureOff, asDaemonUnreachable, asDenied: 4

# ---------------------------------------------------------------------------
# Building the view from what came back
# ---------------------------------------------------------------------------

proc profileKey(profile: ProfileIdentityWire): string =
  if profile.profileIdPresent: profile.profileId else: ""

proc profileLabel*(profile: ProfileIdentityWire): string =
  var parts: seq[string] = @[]
  parts.add(
    if profile.profileIdPresent and profile.profileId.len > 0:
      "profile " & profile.profileId
    else:
      "profile UNKNOWN (this row's hardware was never established)")
  if profile.cpuModel.len > 0:
    parts.add(profile.cpuModel)
  if profile.logicalCores > 0'u64:
    parts.add($profile.logicalCores & " logical cores")
  if profile.hostId.len > 0:
    parts.add("host " & profile.hostId)
  parts.join(" — ")

proc baseView(verb: StatsVerb; options: StatsOptions;
              response: StatsResponseMessage): StatsAnswerView =
  StatsAnswerView(
    verb: verb, statsKey: options.statsKey, status: asOk,
    captureEnabled: response.captureEnabled,
    scopeApplied: response.scopeApplied,
    spanApplied: response.spanApplied,
    ownerUidPresent: response.ownerUidPresent,
    ownerUid: response.ownerUid,
    diagnostic: response.diagnostic,
    caveats: @[], groups: @[], rows: @[], probeRowCount: 0)

proc classify(view: var StatsAnswerView; hasRows: bool; keyNamed: bool;
              probeRows: int) =
  ## THE ORDER IS THE POINT. Capture first, because a store that was never
  ## opened cannot have "no rows"; then the daemon's own refusal, because a
  ## denied query has not looked; then rows; and only then the two flavours
  ## of nothing, told apart by the probe.
  if not view.captureEnabled:
    view.status = asCaptureOff
    view.caveats.add(CaptureOffCaveat)
    return
  if view.diagnostic.code != diagOk:
    view.status = asDenied
    return
  if hasRows:
    view.status = asOk
    return
  view.probeRowCount = probeRows
  if probeRows > 0:
    view.status = asNoRowsInScope
    view.caveats.add(
      "the filters applied here found nothing, but at least " & $probeRows &
      " row(s) for this query exist on the host under a wider scope or " &
      "another hardware profile — retry with --all-users and/or " &
      "--all-profiles.")
  elif keyNamed:
    view.status = asUnknownKey
    view.caveats.add(
      "no execution under this stats key has EVER been recorded on this " &
      "host, at any scope or profile. The key may be misspelled, or the " &
      "work may never have run under a lease.")
  else:
    view.status = asNoData
    view.caveats.add(
      "capture is on and the store is reachable, and it holds no " &
      "executions at all for this query at any scope or profile.")

proc viewOfRanking*(options: StatsOptions; response: StatsResponseMessage;
                    probeRows: int): StatsAnswerView =
  result = baseView(svTop, options, response)
  var order: seq[string] = @[]
  var byKey = initTable[string, ProfileGroup]()
  for entry in response.rankings:
    let key = profileKey(entry.profile)
    if not byKey.hasKey(key):
      order.add(key)
      byKey[key] = ProfileGroup(profile: entry.profile, rankings: @[])
    byKey[key].rankings.add(entry)
  for key in order:
    result.groups.add(byKey[key])
  result.classify(response.rankings.len > 0, options.statsKey.len > 0,
    probeRows)
  if result.spanApplied == profileSpanWireAll and result.groups.len > 1:
    result.caveats.add(MultiProfileCaveat)
  if result.status == asOk:
    result.caveats.add(RankingSpreadCaveat)

proc viewOfExport*(options: StatsOptions; response: StatsResponseMessage;
                   probeRows: int): StatsAnswerView =
  ## The rows are taken VERBATIM. The daemon rendered them because it is
  ## the only component that knows which schema columns are integers; this
  ## one carries them and has no opinion about their contents.
  result = baseView(svExport, options, response)
  for entry in response.extensionRows:
    if entry.values.len == 1:
      result.rows.add(entry.values[0])
  result.classify(result.rows.len > 0, options.statsKey.len > 0, probeRows)
  if result.status == asOk and uint32(result.rows.len) >= options.limit and
      options.limit > 0'u32:
    result.caveats.add(ExportLimitCaveat)

proc unreachableView*(options: StatsOptions; detail: string): StatsAnswerView =
  ## NO DAEMON IS NOT AN EMPTY RESULT EITHER. `runquota acquire` treats a
  ## missing daemon as a non-error and runs the work standalone, which is
  ## right for work and would be very wrong here: a query that answered
  ## "nothing recorded" because nobody was listening is the failure this
  ## module exists to prevent, wearing a different hat.
  StatsAnswerView(
    verb: options.verb, statsKey: options.statsKey,
    status: asDaemonUnreachable, captureEnabled: false,
    scopeApplied: statsScopeWireOwner, spanApplied: profileSpanWireSingle,
    ownerUidPresent: false, ownerUid: 0'u64,
    diagnostic: diagnostic(diagUnavailable,
      "no runquotad answered on the default endpoint", detail),
    caveats: @[
      "runquotad is the only sanctioned reader of the observation store, " &
      "so with no daemon there is no answer to be had — not an empty one."],
    groups: @[], rows: @[], probeRowCount: 0)

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

proc scopeLabel(view: StatsAnswerView): string =
  result =
    case view.scopeApplied
    of statsScopeWireOwner: "scope owner-uid"
    of statsScopeWireHost: "scope host (every user)"
  if view.ownerUidPresent:
    result.add(" " & $view.ownerUid)
  result.add(
    case view.spanApplied
    of profileSpanWireSingle: ", this host profile only"
    of profileSpanWireAll: ", every hardware profile")

proc statusLines*(view: StatsAnswerView): string =
  ## The header every verb prints, and the whole of what `export` writes
  ## to stderr. Capture and status come BEFORE any number, always: a
  ## reader who scrolled past a table to find out whether to believe it
  ## would be reading the table first.
  var lines = @["runquota stats " & $view.verb &
    (if view.statsKey.len > 0: " " & view.statsKey else: "")]
  lines.add("capture: " & (if view.captureEnabled: "ON" else: "OFF") &
    "   status: " & $view.status & "   " & view.scopeLabel())
  if view.diagnostic.code != diagOk:
    lines.add("diagnostic: " & $view.diagnostic.code & ": " &
      view.diagnostic.message &
      (if view.diagnostic.detail.len > 0: " (" & view.diagnostic.detail & ")"
       else: ""))
  for caveat in view.caveats:
    lines.add("! " & caveat)
  lines.join("\n")

proc renderHuman*(view: StatsAnswerView): string =
  var lines = @[statusLines(view)]
  for group in view.groups:
    lines.add("")
    lines.add(profileLabel(group.profile))
    lines.add("  " & align("total", 12) & align("n", 8) &
      align("max", 12) & "  key")
    for entry in group.rankings:
      lines.add("  " & align($entry.totalDurationMillis & "ms", 12) &
        align($entry.sampleCount, 8) &
        align($entry.maxDurationMillis & "ms", 12) & "  " & entry.statsKey)
  lines.join("\n")

proc metadataJson(view: StatsAnswerView): string =
  var caveats: seq[string] = @[]
  for caveat in view.caveats:
    caveats.add(jsonEscape(caveat))
  "\"verb\":" & jsonEscape($view.verb) &
    ",\"stats_key\":" & jsonEscape(view.statsKey) &
    ",\"status\":" & jsonEscape($view.status) &
    ",\"exit_code\":" & $exitCode(view.status) &
    ",\"capture_enabled\":" & (if view.captureEnabled: "true" else: "false") &
    ",\"scope_applied\":" &
    jsonEscape(case view.scopeApplied
      of statsScopeWireOwner: "owner-uid"
      of statsScopeWireHost: "host") &
    ",\"span_applied\":" &
    jsonEscape(case view.spanApplied
      of profileSpanWireSingle: "single-profile"
      of profileSpanWireAll: "all-profiles") &
    ",\"owner_uid\":" &
    (if view.ownerUidPresent: $view.ownerUid else: "null") &
    ",\"diagnostic\":{\"code\":" & jsonEscape($view.diagnostic.code) &
    ",\"message\":" & jsonEscape(view.diagnostic.message) &
    ",\"detail\":" & jsonEscape(view.diagnostic.detail) & "}" &
    ",\"widened_probe_row_count\":" & $view.probeRowCount &
    ",\"caveats\":[" & caveats.join(",") & "]"

proc renderJson*(view: StatsAnswerView): string =
  ## THE SAME CAVEATS, NOT JUST THE SAME NUMBERS. An agent parsing this
  ## must be able to tell capture-off from no-rows without reading prose it
  ## was never given.
  var body = ""
  case view.verb
  of svTop:
    var groups: seq[string] = @[]
    for group in view.groups:
      var rows: seq[string] = @[]
      for entry in group.rankings:
        rows.add("{\"stats_key\":" & jsonEscape(entry.statsKey) &
          ",\"sample_count\":" & $entry.sampleCount &
          ",\"total_duration_millis\":" & $entry.totalDurationMillis &
          ",\"max_duration_millis\":" & $entry.maxDurationMillis & "}")
      # NESTED UNDER THE PROFILE they were measured on, so an agent that
      # wants one flat ranking has to write the pooling itself and thereby
      # own it.
      groups.add("{\"profile\":{\"profile_id\":" &
        (if group.profile.profileIdPresent:
           jsonEscape(group.profile.profileId) else: "null") &
        ",\"host_id\":" & jsonEscape(group.profile.hostId) &
        ",\"cpu_model\":" & jsonEscape(group.profile.cpuModel) &
        ",\"logical_cores\":" & $group.profile.logicalCores &
        "},\"rankings\":[" & rows.join(",") & "]}")
    body = ",\"profiles\":[" & groups.join(",") & "]"
  of svExport:
    body = ",\"rows\":[" & view.rows.join(",") & "]"
  of svCapture:
    discard
  "{" & metadataJson(view) & body & "}"

proc renderNdjson*(view: StatsAnswerView): string =
  ## STDOUT FOR `export`, and nothing but rows. A status line here would
  ## break the `jq` pipe the verb exists for; the status is on stderr and
  ## in the exit code, where it breaks nothing.
  view.rows.join("\n")

proc renderCapture*(captureEnabled: bool; detail: string;
                    asJson: bool): string =
  ## `stats capture`, rendered from the SAME `captureEnabled` bit the
  ## other verbs gate their answers on, taken from a real stats reply
  ## rather than from the inspection surface beside it. Two sources for
  ## one fact is how a command comes to say capture is on while the verb
  ## next to it returns nothing. `detail` is the daemon's `observations`
  ## object verbatim — store path, counters, retention — carried through
  ## without being re-interpreted here.
  let status = if captureEnabled: asOk else: asCaptureOff
  var caveats: seq[string] = @[]
  if not captureEnabled:
    caveats.add(CaptureOffCaveat)
  if asJson:
    var encoded: seq[string] = @[]
    for caveat in caveats:
      encoded.add(jsonEscape(caveat))
    result = "{\"verb\":\"capture\",\"status\":" & jsonEscape($status) &
      ",\"exit_code\":" & $exitCode(status) &
      ",\"capture_enabled\":" & (if captureEnabled: "true" else: "false") &
      ",\"caveats\":[" & encoded.join(",") & "]" &
      ",\"daemon_observations\":" & detail & "}"
  else:
    var lines = @["runquota stats capture",
      "capture: " & (if captureEnabled: "ON" else: "OFF") &
        "   status: " & $status]
    for caveat in caveats:
      lines.add("! " & caveat)
    lines.add("daemon detail: " & detail)
    result = lines.join("\n")
