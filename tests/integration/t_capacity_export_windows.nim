## The capacity figures a private `runquotad` keeps for capacity tools, read
## back the two ways it publishes them, ON WINDOWS: `runquota status --json`
## (`capacity`) and the Prometheus text file `--metrics-textfile` writes.
##
## THE WINDOWS ARM of `tests/integration/t_capacity_export.nim`. That file is
## `when defined(linux):` and drives `private_daemon_fixture`, a Unix-socket
## daemon under the `private` endpoint scope -- neither exists here. Windows has
## no `private` scope (the daemon refuses it) and no Unix socket; the transport
## is a named pipe under `host` scope, which `windows_daemon_fixture` isolates
## with a pipe name no concurrent run collides with. The ledger, the counters,
## the saturation and the exposition rendering are the same cross-platform Nim
## (`libs/runquota_daemon/tests/t_capacity_metrics`, which the Windows gate
## runs, pins them as pure functions); this file proves the MECHANISM runs over
## the Windows transport, and that the ONE platform split in the module -- the
## `else:` arm of `writeTextfileAtomically`, `writeFile`/`moveFile` where the
## POSIX arm is raw `open`/`write`/`rename` -- keeps the atomicity the POSIX arm
## does.
##
## WHAT IS GUARDED, and the mutation each check fails under.
##
## 1. The used-CPU counter comes from what finishes REPORT. Two leases of a
##    session group finish reporting 10 s and 20 s of CPU in their totals; the
##    group's counter (and the host's) rises by exactly 30 s, and the CPU
##    granted to the group is back to zero once both have finished. The leases
##    are granted 4 CPUs each and finish at once, so counting granted width x
##    held time instead of the reported CPU (the falsifying mutation) yields a
##    few CPU-seconds at most and fails. A finish without totals adds no CPU and
##    is counted as a finish without totals, never as zero CPU. The same figures
##    read back through `runquota status --json`'s `capacity` key.
## 2. The text file is valid: it parses and lints under Prometheus's own
##    `promtool check metrics` when it is on PATH (as the Linux file does, it
##    tolerates its absence -- the Windows runner does not ship it -- and
##    hand-parses the exposition grammar instead), with group names that need
##    escaping (a double quote, a backslash) and one that is not UTF-8. The host
##    and group `cpu_used` counters carry the reported figures, and `runquota
##    status --json` reports the writer's write and failure counts.
## 3. `writeTextfileAtomically`'s Windows arm is atomic: writing the file twice
##    in a row with different content leaves exactly the second content and no
##    temporary file, and a reader racing a stream of alternating writes never
##    sees a partial or mixed file -- only one whole content or the other. This
##    is the atomicity guarantee the POSIX arm provides through `rename(2)`;
##    `moveFile` reaches it through `MoveFileEx(MOVEFILE_REPLACE_EXISTING)` over
##    a temporary in the same directory (so the same volume, where the replace
##    is atomic on NTFS).
##
## NO MOCKS: the built `runquotad` and `runquota`, real sessions over a real
## named pipe. The leases finish through the client library with known totals
## (as the Linux file's do), so there is no shell and no child to reap.

when defined(windows):
  import std/[json, os, osproc, strutils, unittest]

  import runquota_client
  import runquota_core
  import runquota_protocol
  import runquota_daemon/capacity_metrics
  import daemon_binary
  import windows_daemon_fixture

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  proc startCapacityDaemon(prefix: string; extra: openArray[string]): Daemon =
    ## Like the fixture's `startDaemon`, but with the daemon flags this suite
    ## needs (a wide CPU budget and, for the text-file suite, a metrics file)
    ## rather than a fixed `--cpu-milli`.
    result.root = scratchDir(prefix)
    result.pipe = uniquePipe()
    result.env = hostEnv(result.pipe)
    result.process = startProcess(daemonPath(), env = result.env,
      args = daemonArgs(result.root, result.pipe, extra),
      options = {poStdErrToStdOut})
    prerequisite awaitDaemon(result),
      "the daemon did not serve " & result.pipe

  proc useDaemon(daemon: Daemon) =
    ## Point THIS process's in-process client at the daemon's pipe. The CLI
    ## subprocesses get `daemon.env` directly; `connectDefault` reads the
    ## process environment.
    putEnv("RUNQUOTA_SOCKET", daemon.pipe)

  proc cpuTotals(micros: uint64): FinishTotals =
    FinishTotals(known: true, cpuUserMicros: micros div 4 * 3,
      cpuSysMicros: micros - micros div 4 * 3, durationMillis: 500)

  proc runLease(session: var RunQuotaSession; cpuMilli: uint32;
                totals: FinishTotals) =
    ## One lease, granted, run and finished with `totals`, then released.
    var request = resourceRequest("capacity", milliCpu(cpuMilli),
      bytes(64'u64 * 1024'u64 * 1024'u64))
    var lease = session.requestLease(request)
    prerequisite lease.active, "the lease was not granted"
    lease.markStarting()
    lease.markRunning(childProcessId = uint64(getCurrentProcessId()))
    lease.finish(outcome = succeeded(), totals = totals)
    lease.release()

  proc u64(node: JsonNode): uint64 =
    ## A JSON integer that may exceed `int64`: plain `parseJson` keeps those
    ## that fit `int64` as `JInt`, and a daemon counter that saturated to
    ## `high(uint64)` would arrive as text.
    if node.kind == JInt: uint64(node.getBiggestInt)
    else: parseBiggestUInt(node.getStr)

  proc rawCapacity(daemon: Daemon): JsonNode =
    let r = runq(daemon.env, ["status", "--json"])
    prerequisite r.code == 0, "runquota status --json exit " & $r.code
    parseJson(r.output)["capacity"]

  proc rawGroup(cap: JsonNode; name: string): JsonNode =
    for group in cap["groups"]:
      if group["name"].getStr == name:
        return group
    newJNull()

  # -------------------------------------------------------------------
  # The used-CPU counter
  # -------------------------------------------------------------------

  suite "the used-CPU counter (windows)":
    test "two finishes reporting 10 s and 20 s raise the group's counter by 30 s":
      var daemon = startCapacityDaemon("rqcapw", ["--cpu-milli", "16000"])
      defer: daemon.stop()
      useDaemon(daemon)
      var client = connectDefault()
      defer: client.close()
      var session = client.registerSession("capacity", "0.1.0",
        SessionGroupDeclaration(name: "cap-build"))
      # A lease that holds capacity while the figures are read, so "granted" is
      # seen to be live before it is seen to drop.
      var held = session.requestLease(resourceRequest("held",
        milliCpu(2000), bytes(256'u64 * 1024'u64 * 1024'u64)))
      prerequisite held.active, "the held lease was not granted"
      let before = daemon.rawCapacity()
      let groupBefore = before.rawGroup("cap-build")
      check groupBefore.kind == JObject
      check groupBefore["cpu_granted_milli"].u64 == 2000
      check groupBefore["memory_reserved_bytes"].u64 == 256'u64 * 1024 * 1024
      check groupBefore["cpu_used_micros"].u64 == 0
      session.runLease(4000, cpuTotals(10_000_000))
      session.runLease(4000, cpuTotals(20_000_000))
      held.release()
      let after = daemon.rawCapacity()
      let group = after.rawGroup("cap-build")
      checkpoint $after
      check group["cpu_used_micros"].u64 == 30_000_000'u64
      check after["host"]["cpu_used_micros"].u64 == 30_000_000'u64
      check group["finished_with_totals"].u64 == 2
      check group["cpu_granted_milli"].u64 == 0
      check group["memory_reserved_bytes"].u64 == 0
      check after["host"]["cpu_granted_milli"].u64 == 0
      # Three grants: the held lease and the two that finished.
      check group["grants"].u64 == 3
      # A finish without totals is a finish the counter does not cover.
      session.runLease(4000, FinishTotals(known: false))
      let missing = daemon.rawCapacity().rawGroup("cap-build")
      check missing["cpu_used_micros"].u64 == 30_000_000'u64
      check missing["finished_with_totals"].u64 == 2
      check missing["finished_without_totals"].u64 == 1
      session.closeSession()
      # The group outlives its last session: its counter stays readable.
      let closed = daemon.rawCapacity().rawGroup("cap-build")
      check closed.kind == JObject
      check closed["cpu_used_micros"].u64 == 30_000_000'u64

  # -------------------------------------------------------------------
  # The metrics text file
  # -------------------------------------------------------------------

  proc awaitFileWith(path, needle: string; budgetMillis = 30_000): string =
    var waited = 0
    while waited < budgetMillis:
      if fileExists(path):
        let text = readFile(path)
        if needle in text:
          return text
      sleep(50)
      waited += 50
    ""

  type
    MetricSample = tuple[name, labels: string]

  proc isMetricName(name: string): bool =
    ## `[a-zA-Z_:][a-zA-Z0-9_:]*`.
    if name.len == 0: return false
    for i, ch in name:
      let ok =
        if i == 0: ch in {'a'..'z', 'A'..'Z', '_', ':'}
        else: ch in {'a'..'z', 'A'..'Z', '0'..'9', '_', ':'}
      if not ok: return false
    true

  proc isFloat(value: string): bool =
    ## A Prometheus sample value: a Go float, or one of the special tokens.
    if value in ["+Inf", "-Inf", "Inf", "NaN"]: return true
    try:
      discard parseFloat(value)
      true
    except ValueError:
      false

  proc parseLabels(blockText: string; ok: var bool): string =
    ## Validate a `{...}` label block (its interior, no braces) and return it
    ## verbatim for duplicate detection. Checks label names, that each value is
    ## a double-quoted string, and that the only backslash escapes are the
    ## three the format allows (`\\`, `\"`, `\n`).
    ok = true
    var i = 0
    let s = blockText
    if s.strip().len == 0:
      return ""
    while i < s.len:
      # label name
      var name = ""
      while i < s.len and s[i] in {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
        name.add(s[i]); inc i
      if name.len == 0 or not (name[0] in {'a'..'z', 'A'..'Z', '_'}):
        ok = false; return ""
      if i >= s.len or s[i] != '=': ok = false; return ""
      inc i
      if i >= s.len or s[i] != '"': ok = false; return ""
      inc i
      while i < s.len and s[i] != '"':
        if s[i] == '\\':
          inc i
          if i >= s.len or s[i] notin {'\\', '"', 'n'}: ok = false; return ""
        inc i
      if i >= s.len: ok = false; return ""  # unterminated value
      inc i  # closing quote
      if i < s.len and s[i] == ',':
        inc i
        if i >= s.len: ok = false; return ""  # trailing comma
      elif i != s.len:
        ok = false; return ""
    blockText

  proc checkExposition(text: string): tuple[ok: bool, why: string] =
    ## Hand-parse the Prometheus text exposition format (0.0.4) well enough to
    ## stand in for `promtool check metrics` when it is off PATH: every sample
    ## line is `name[{labels}] value`, names and values are well formed, label
    ## blocks are balanced and correctly escaped, and no `name{labels}` pair
    ## repeats. Tolerant of its absence exactly as the Linux file is.
    var seen: seq[MetricSample]
    for rawLine in text.splitLines():
      let line = rawLine
      if line.strip().len == 0: continue
      if line.startsWith("#"):
        # `# HELP name ...` / `# TYPE name type` or a free comment.
        let parts = line.splitWhitespace()
        if parts.len >= 2 and parts[1] in ["HELP", "TYPE"]:
          if parts.len < 3 or not isMetricName(parts[2]):
            return (false, "malformed " & parts[1] & " line: " & line)
        continue
      # A sample line.
      var name = ""
      var i = 0
      while i < line.len and line[i] notin {'{', ' '}:
        name.add(line[i]); inc i
      if not isMetricName(name):
        return (false, "bad metric name: " & line)
      var labels = ""
      if i < line.len and line[i] == '{':
        let close = line.rfind('}')
        if close < 0 or close < i:
          return (false, "unbalanced label braces: " & line)
        var labelsOk = false
        labels = parseLabels(line[i + 1 ..< close], labelsOk)
        if not labelsOk:
          return (false, "bad label block: " & line)
        i = close + 1
      # Skip the single space before the value.
      let rest = line[i .. ^1].strip()
      let fields = rest.splitWhitespace()
      if fields.len < 1 or fields.len > 2:
        return (false, "expected value [timestamp]: " & line)
      if not isFloat(fields[0]):
        return (false, "bad sample value: " & line)
      let key: MetricSample = (name, labels)
      if key in seen:
        return (false, "duplicate series: " & name & "{" & labels & "}")
      seen.add(key)
    (true, "")

  suite "the metrics text file (windows)":
    test "it is valid exposition with names that need escaping; status reports the writer":
      let textRoot = scratchDir("rqcaptextw")
      defer: removeDir(textRoot)
      let textPath = textRoot / "runquota.prom"
      var daemon = startCapacityDaemon("rqcappubw",
        ["--cpu-milli", "16000", "--metrics-textfile", textPath,
         "--metrics-interval-millis", "100"])
      defer: daemon.stop()
      useDaemon(daemon)
      var client = connectDefault()
      defer: client.close()
      let names = ["plain", "quote\"d", "back\\slash", "not-utf8-\xff\xfe"]
      for name in names:
        var session = client.registerSession("capacity", "0.1.0",
          SessionGroupDeclaration(name: name))
        session.runLease(1000, cpuTotals(1_000_000))
        session.closeSession()
      # Four finishes with totals, 1 s of CPU each: the host counter reaches
      # 4 s once every group's finish is in the file.
      let text = awaitFileWith(textPath,
        "runquota_host_cpu_used_seconds_total 4.000000")
      check text.len > 0
      checkpoint text

      # The labels are escaped as the format requires, and a name that is not
      # UTF-8 carries its bytes in hex so it stays its own series.
      check "runquota_group_cpu_used_seconds_total{owner_uid=\"" in text
      check "group=\"quote\\\"d\"" in text
      check "group=\"back\\\\slash\"" in text
      check "group_hex=\"" & toHex("not-utf8-\xff\xfe").toLowerAscii() &
        "\"" in text

      # `promtool` lints it when the host provides it; otherwise the hand-parse
      # stands in, exactly as the build-wait-pressure Windows leg does.
      let promtool = findExe("promtool")
      if promtool.len > 0:
        let (output, code) = execCmdEx(quoteShell(promtool) &
          " check metrics < " & quoteShell(textPath))
        checkpoint output
        check code == 0
        check output.strip().len == 0
      else:
        checkpoint "promtool is not on PATH; hand-parsing the exposition grammar"
        let (ok, why) = checkExposition(text)
        check ok
        if not ok: checkpoint why

      let status = daemon.rawCapacity()
      check status["textfile"]["writes"].u64 > 0
      check status["textfile"]["failures"].u64 == 0
      # The same figures the file carries are in `status --json`.
      check status["host"]["cpu_used_micros"].u64 == 4_000_000'u64
      check status.rawGroup("plain")["cpu_used_micros"].u64 == 1_000_000'u64
      check status.rawGroup("plain")["finished_with_totals"].u64 == 1

  # -------------------------------------------------------------------
  # The text-file writer's atomicity (the Windows `else:` arm)
  # -------------------------------------------------------------------

  proc tempSiblings(path: string): seq[string] =
    ## Any `.<name>.<pid>.tmp` left beside `path` by the writer.
    let (dir, name, ext) = splitFile(path)
    for kind, found in walkDir(if dir.len > 0: dir else: "."):
      let base = extractFilename(found)
      if base.startsWith("." & name & ext & ".") and base.endsWith(".tmp"):
        result.add(found)

  # Shared with the racing reader thread below.
  var readerArgs: tuple[path, a, b: string]
  var readerCorrupt {.global.}: bool
  var readerReads {.global.}: int

  proc readerBody() {.thread.} =
    ## Read the file as fast as it can for a while; flag any content that is
    ## neither of the two whole contents (a partial or mixed file). A transient
    ## open failure (the reader raced the replace) is not corruption.
    ##
    ## `cast(gcsafe)`: the reader only READS `readerArgs`, which the test sets
    ## before the thread starts and never mutates while it runs, and the two
    ## contents are immutable; ORC's heap is shared across threads, so the read
    ## is safe though the analysis cannot see that the global is quiescent.
    {.cast(gcsafe).}:
      let path = readerArgs.path
      let a = readerArgs.a
      let b = readerArgs.b
      for _ in 0 ..< 4000:
        try:
          let got = readFile(path)
          inc readerReads
          if got != a and got != b:
            readerCorrupt = true
        except CatchableError:
          discard

  suite "the text-file writer is atomic (windows)":
    test "two writes in a row leave the second whole, and no temporary":
      let root = scratchDir("rqcapatomw")
      defer: removeDir(root)
      let path = root / "runquota.prom"
      let first = "FIRST\n" & repeat("a", 200_000) & "\n"
      let second = "SECOND\n" & repeat("b", 150_000) & "\n"
      check writeTextfileAtomically(path, first) == ""
      check readFile(path) == first
      check writeTextfileAtomically(path, second) == ""
      check readFile(path) == second
      # The temporary is renamed away, never left behind.
      check tempSiblings(path).len == 0

    test "a reader racing a stream of writes never sees a partial or mixed file":
      let root = scratchDir("rqcapracew")
      defer: removeDir(root)
      let path = root / "runquota.prom"
      let a = "AAAA\n" & repeat("a", 300_000) & "\n"
      let b = "BB\n" & repeat("b", 120_000) & "\n"
      # Seed the file so the reader always finds a whole content.
      check writeTextfileAtomically(path, a) == ""
      readerArgs = (path, a, b)
      readerCorrupt = false
      readerReads = 0
      var reader: Thread[void]
      createThread(reader, readerBody)
      var writes = 0
      var failures = 0
      for i in 0 ..< 600:
        let err = writeTextfileAtomically(path, if i mod 2 == 0: b else: a)
        if err.len == 0: inc writes
        else: inc failures
      joinThread(reader)
      checkpoint "writes " & $writes & " failures " & $failures &
        " reads " & $readerReads & " corrupt " & $readerCorrupt
      # The reader saw only whole contents, never a part or a mix.
      check not readerCorrupt
      # The writes landed (a replace may lose a race to a reader holding the
      # file, which leaves the OLD whole file -- never a partial one -- so a
      # few failures are allowed, but the mechanism must mostly work).
      check writes > 0
      check readerReads > 0
      # A deterministic final write lands whole.
      check writeTextfileAtomically(path, a) == ""
      check readFile(path) == a
      check tempSiblings(path).len == 0

else:
  echo "t_capacity_export_windows: Windows only"
