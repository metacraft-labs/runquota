## The RunQuota observation store: one durable, immutable row per executed
## process, with the host and hardware dimension, ambient load, and a
## registry for product-owned extension tables.
##
## Normative specification:
## ``reprobuild-specs/RunQuota-Observation-Store.md``. Repository posture:
## ``docs/database.md``.
##
## Two rules shape every entry point below.
##
## * **Degrade, never fail (OS-4).** Nothing here raises. A missing
##   ``sqlite3``, a corrupt file, an unwritable directory, or a database
##   written by a newer RunQuota all produce a store whose ``status`` is not
##   ``ssOpen`` and whose ``report`` says why. Callers check
##   ``captureEnabled`` and carry on; a build or a test run MUST NOT fail
##   because observation is unavailable.
## * **Immutable rows (OS-3).** ``executions`` carries a ``before update``
##   trigger that aborts. There is deliberately no update entry point, and
##   the trigger holds even for a client using ``sqlite3`` directly.

import std/[options, os, strutils]

import ./hardware, ./ids, ./schema, ./sqlite_cli, ./types

export types
export ids
export hardware
export schema.spineSchemaVersion, schema.spineTableNames

const libraryName* = "runquota_observation_store"

type
  ObservationStore* = ref object
    path*: string
    status*: StoreStatus
    report*: string
    schemaVersion*: int64
    lastError*: string
      ## The most recent rejected write. A rejected row is the caller's
      ## problem; it does not turn capture off.

proc libraryInfo*(): LibraryInfo =
  LibraryInfo(name: libraryName)

proc captureEnabled*(store: ObservationStore): bool =
  not store.isNil and store.status == ssOpen

proc oneLine(text: string): string =
  ## Folds every embedded newline out of a report.
  ##
  ## ``report`` IS ONE LINE, ALWAYS, for the same reason ``HostIdentity``'s
  ## is: the daemon prints it as one of a FIXED number of startup lines and
  ## a reader consumes that output by count, so a report that is silently
  ## two lines leaves every reader of the next one blocked or misaligned.
  ##
  ## The sources that embed one are real and reached by the default
  ## configuration, not by an exotic one. ``OSError.msg`` on macOS is two
  ## lines -- the message and an "Additional info:" line -- and it is what
  ## an unprovisionable parent directory produces; ``sqlite3``'s stderr is
  ## multi-line whenever it reports more than one thing. Folding here
  ## rather than at each construction site is what makes the guarantee
  ## hold for the branches added later, too.
  var parts: seq[string] = @[]
  for line in text.splitLines:
    let trimmed = line.strip()
    if trimmed.len > 0:
      parts.add(trimmed)
  parts.join(" ")

proc degrade(store: ObservationStore; status: StoreStatus; report: string) =
  store.status = status
  store.report = oneLine(report)

# ---------------------------------------------------------------------------
# Opening, integrity, and migration
# ---------------------------------------------------------------------------

proc readUserVersion(path: string; version: var int64; detail: var string): bool =
  let outcome = runSqlite(path, "pragma user_version;")
  if not outcome.ok:
    detail = outcome.error.strip()
    return false
  let text = outcome.output.strip()
  try:
    version = parseBiggestInt(text)
    true
  except ValueError:
    detail = "unreadable user_version: " & text
    false

proc integrityDetail(path: string): string =
  ## Empty string means the database is intact. Anything else is the
  ## reason it is not, reported verbatim rather than repaired.
  let outcome = runSqlite(path, "pragma quick_check;")
  if not outcome.ok:
    let detail = outcome.error.strip()
    return if detail.len > 0: detail else: "sqlite3 exited " & $outcome.exitCode
  let text = outcome.output.strip()
  if text != "ok":
    return "quick_check reported: " & text
  ""

proc missingSpineTables(path: string): seq[string] =
  var quoted: seq[string] = @[]
  for name in spineTableNames:
    quoted.add(encodeText(name))
  let outcome = runSqlite(path,
    "select name from sqlite_master where type = 'table' and name in (" &
      quoted.join(", ") & ") order by name;")
  if not outcome.ok:
    return @spineTableNames
  var present: seq[string] = @[]
  for line in outcome.output.splitLines():
    if line.len > 0:
      present.add(line)
  for name in spineTableNames:
    if name notin present:
      result.add(name)

proc applyMigrations(store: ObservationStore; fromVersion: int64): bool =
  var current = fromVersion
  while current < spineSchemaVersion:
    let step = migrations[int(current)]
    let outcome = runSqlite(store.path,
      "begin immediate;\n" & step & "\npragma user_version = " &
        $(current + 1) & ";\ncommit;")
    if not outcome.ok:
      store.degrade(ssUnwritable,
        "runquota observation store " & store.path & ": migration to schema " &
          $(current + 1) & " failed: " & outcome.error.strip() &
          "; capture disabled")
      return false
    current += 1
  store.schemaVersion = current
  true

proc openObservationStore*(path: string): ObservationStore =
  ## Opens (creating if necessary) the store at ``path``. Never raises.
  result = ObservationStore(path: path, status: ssOpen, report: "",
                            schemaVersion: -1)
  if path.len == 0:
    result.degrade(ssDisabled,
      "runquota observation store: no path configured; capture disabled")
    return
  if not sqliteToolAvailable():
    result.degrade(ssNoSqliteTool,
      "runquota observation store " & path & ": the '" & sqliteTool &
        "' tool is not on PATH; capture disabled")
    return
  let parent = path.parentDir
  if parent.len > 0 and not dirExists(parent):
    try:
      createDir(parent)
    except CatchableError as error:
      result.degrade(ssUnwritable,
        "runquota observation store " & path & ": cannot create " & parent &
          ": " & error.msg & "; capture disabled")
      return

  let existed = fileExists(path)
  if existed:
    let detail = integrityDetail(path)
    if detail.len > 0:
      result.degrade(ssCorrupt,
        "runquota observation store " & path &
          ": database is corrupt and was left untouched (" & detail &
          "); capture disabled")
      return

  var version: int64
  var detail = ""
  if not readUserVersion(path, version, detail):
    result.degrade(ssCorrupt,
      "runquota observation store " & path &
        ": schema version is unreadable (" & detail &
        "); capture disabled")
    return

  if version > spineSchemaVersion:
    result.schemaVersion = version
    result.degrade(ssRefusedNewer,
      "runquota observation store " & path & ": refusing to open schema " &
        $version & ", this build understands at most " & $spineSchemaVersion &
        "; the database was not modified and capture is disabled")
    return

  if version < spineSchemaVersion:
    if not result.applyMigrations(version):
      return
  else:
    result.schemaVersion = version

  let missing = missingSpineTables(path)
  if missing.len > 0:
    result.degrade(ssCorrupt,
      "runquota observation store " & path & ": schema " &
        $result.schemaVersion & " is missing table(s) " & missing.join(", ") &
        "; capture disabled")
    return

  let walOutcome = runSqlite(path, "pragma journal_mode = wal;")
  if not walOutcome.ok:
    result.degrade(ssUnwritable,
      "runquota observation store " & path & ": cannot enable WAL (" &
        walOutcome.error.strip() & "); capture disabled")
    return
  result.report = "runquota observation store " & path & ": schema " &
    $result.schemaVersion & "; capture enabled"

proc backupTo*(store: ObservationStore; destination: string): bool =
  ## Copies a consistent snapshot while writers stay live. ``VACUUM INTO``
  ## takes a read transaction, so the copy is usable standalone and the
  ## daemon does not have to stop.
  if not store.captureEnabled:
    return false
  if fileExists(destination):
    return false
  runSqlite(store.path, "vacuum into " & encodeText(destination) & ";").ok

# ---------------------------------------------------------------------------
# Encoding helpers for optional columns
# ---------------------------------------------------------------------------

proc encodeOptText(value: Option[string]): string =
  if value.isNone: "null" else: encodeText(value.get)

proc encodeOptInt(value: Option[int64]): string =
  if value.isNone: "null" else: encodeInt(value.get)

proc decodeOptText(field: string): Option[string] =
  if field.isNullField: none(string) else: some(decodeText(field))

proc decodeOptInt(field: string): Option[int64] =
  if field.isNullField: none(int64) else: some(parseBiggestInt(field))

# ---------------------------------------------------------------------------
# Statement builders. Column order is written once per table and reused by
# both the insert and the select, so the two cannot drift apart.
# ---------------------------------------------------------------------------

const
  hostColumns = ["host_id", "created_at_unix_millis", "last_boot_id"]

  hostProfileColumns = [
    "host_id", "profile_id", "profile_hash", "valid_from_unix_millis",
    "valid_to_unix_millis", "cpu_model", "physical_cores", "logical_cores",
    "ram_bytes", "swap_bytes", "disk_class", "fs_type", "arch", "os",
    "os_version", "kernel_version", "virtualization", "cpu_share_group"]

  runColumns = [
    "run_id", "host_id", "tool", "tool_version", "invocation_kind",
    "started_at_unix_millis", "finished_at_unix_millis", "exit_status",
    "workspace_id", "profile", "git_commit", "git_branch",
    "capture_completeness", "dropped_observations"]

  executionColumns = [
    "execution_id", "host_id", "host_profile_id", "run_id",
    "command_stats_id", "lease_id", "started_at_unix_millis",
    "finished_at_unix_millis", "duration_millis", "exit_status",
    "termination", "attempt", "retry_of", "peak_rss_bytes",
    "cpu_user_millis", "cpu_sys_millis", "max_processes",
    "major_page_faults", "io_read_bytes", "io_write_bytes",
    "capture_completeness", "dropped_observations", "owner_uid"]

  ambientColumns = [
    "host_id", "sampled_at_unix_millis", "cpu_busy_pct",
    "mem_available_bytes", "swap_in_rate", "io_queue_depth", "load_avg_1m",
    "self_cpu_pct", "self_rss_bytes", "foreign_cpu_pct", "foreign_rss_bytes"]

  extensionColumns = [
    "extension_id", "schema_version", "owner", "table_name",
    "registered_at_unix_millis"]

proc insertStatement(table: string; columns: openArray[string];
                     values: openArray[string]): string =
  "insert into " & table & " (" & columns.join(", ") & ") values (" &
    values.join(", ") & ");"

proc hostValues(row: HostRow): seq[string] =
  @[encodeText(row.hostId), encodeInt(row.createdAtUnixMillis),
    encodeText(row.lastBootId)]

proc hostProfileValues(row: HostProfileRow): seq[string] =
  @[encodeText(row.hostId), encodeText(row.profileId),
    encodeText(row.profileHash), encodeInt(row.validFromUnixMillis),
    encodeOptInt(row.validToUnixMillis), encodeText(row.cpuModel),
    encodeInt(row.physicalCores), encodeInt(row.logicalCores),
    encodeInt(row.ramBytes), encodeInt(row.swapBytes),
    encodeText($row.diskClass), encodeText(row.fsType), encodeText(row.arch),
    encodeText(row.os), encodeText(row.osVersion),
    encodeText(row.kernelVersion), encodeText(row.virtualization),
    encodeText(row.cpuShareGroup)]

proc runValues(row: RunRow): seq[string] =
  @[encodeText(row.runId), encodeText(row.hostId), encodeText(row.tool),
    encodeText(row.toolVersion), encodeText(row.invocationKind),
    encodeInt(row.startedAtUnixMillis),
    encodeOptInt(row.finishedAtUnixMillis), encodeOptInt(row.exitStatus),
    encodeOptText(row.workspaceId), encodeOptText(row.profile),
    encodeOptText(row.gitCommit), encodeOptText(row.gitBranch),
    encodeText($row.captureCompleteness), encodeInt(row.droppedObservations)]

proc executionValues(row: ExecutionRow): seq[string] =
  @[encodeText(row.executionId), encodeText(row.hostId),
    encodeOptText(row.hostProfileId), encodeText(row.runId),
    encodeText(row.commandStatsId), encodeOptInt(row.leaseId),
    encodeInt(row.startedAtUnixMillis), encodeInt(row.finishedAtUnixMillis),
    encodeInt(row.durationMillis), encodeInt(row.exitStatus),
    encodeText($row.termination), encodeInt(row.attempt),
    encodeOptText(row.retryOf), encodeInt(row.peakRssBytes),
    encodeOptInt(row.cpuUserMillis), encodeOptInt(row.cpuSysMillis),
    encodeInt(row.maxProcesses), encodeInt(row.majorPageFaults),
    encodeOptInt(row.ioReadBytes), encodeOptInt(row.ioWriteBytes),
    encodeText($row.captureCompleteness), encodeInt(row.droppedObservations),
    encodeOptInt(row.ownerUid)]

proc ambientValues(row: AmbientSampleRow): seq[string] =
  @[encodeText(row.hostId), encodeInt(row.sampledAtUnixMillis),
    encodeFloat(row.cpuBusyPct), encodeInt(row.memAvailableBytes),
    encodeFloat(row.swapInRate), encodeFloat(row.ioQueueDepth),
    encodeFloat(row.loadAvg1m), encodeFloat(row.selfCpuPct),
    encodeInt(row.selfRssBytes), encodeFloat(row.foreignCpuPct),
    encodeInt(row.foreignRssBytes)]

proc extensionValues(row: ExtensionRegistryRow): seq[string] =
  @[encodeText(row.extensionId), encodeInt(row.schemaVersion),
    encodeText(row.owner), encodeText(row.tableName),
    encodeInt(row.registeredAtUnixMillis)]

proc isRejection(error: string): bool =
  ## A row the schema refused, as opposed to a store that has stopped
  ## working. The first is the caller's mistake and must not disable
  ## capture for everyone else; the second must.
  let lowered = error.toLowerAscii
  "constraint" in lowered or "datatype mismatch" in lowered

proc execute(store: ObservationStore; sql: string): bool =
  ## Runs ``sql`` when capture is enabled. Never raises. A store that has
  ## stopped accepting writes degrades to no capture so the next caller
  ## stops paying for it.
  if not store.captureEnabled:
    return false
  let outcome = runSqlite(store.path, sql)
  if not outcome.ok:
    store.lastError = outcome.error.strip()
    if not isRejection(store.lastError):
      store.degrade(ssUnwritable,
        "runquota observation store " & store.path & ": write failed (" &
          store.lastError & "); capture disabled")
    return false
  true

proc insertHost*(store: ObservationStore; row: HostRow): bool =
  store.execute(insertStatement("hosts", hostColumns, hostValues(row)))

proc insertHostProfile*(store: ObservationStore; row: HostProfileRow): bool =
  store.execute(insertStatement("host_profiles", hostProfileColumns,
    hostProfileValues(row)))

proc insertRun*(store: ObservationStore; row: RunRow): bool =
  store.execute(insertStatement("runs", runColumns, runValues(row)))

proc insertExecution*(store: ObservationStore; row: ExecutionRow): bool =
  store.execute(insertStatement("executions", executionColumns,
    executionValues(row)))

proc insertAmbientSample*(store: ObservationStore;
                          row: AmbientSampleRow): bool =
  store.execute(insertStatement("ambient_samples", ambientColumns,
    ambientValues(row)))

proc registerExtension*(store: ObservationStore;
                        row: ExtensionRegistryRow): bool =
  store.execute(insertStatement("extension_registry", extensionColumns,
    extensionValues(row)))

proc batchStatement*(runs: openArray[RunRow];
                     executions: openArray[ExecutionRow]): string =
  ## One transaction for a drained queue. ``insert or ignore`` for runs
  ## because several executions share a run and the row may already exist.
  result = "begin immediate;\n"
  for row in runs:
    result.add("insert or ignore into runs (" & runColumns.join(", ") &
      ") values (" & runValues(row).join(", ") & ");\n")
  for row in executions:
    result.add(insertStatement("executions", executionColumns,
      executionValues(row)) & "\n")
  result.add("commit;\n")

proc appendBatchAt*(path: string; runs: openArray[RunRow];
                    executions: openArray[ExecutionRow]): SqliteOutcome =
  ## Path-addressed batch append, for the background writer: it must not
  ## touch the ``ObservationStore`` ref owned by the daemon thread.
  if runs.len == 0 and executions.len == 0:
    return SqliteOutcome(ok: true, exitCode: 0, output: "", error: "")
  runSqlite(path, batchStatement(runs, executions))

proc ambientBatchStatement*(rows: openArray[AmbientSampleRow]): string =
  ## One transaction for a drained run of ambient samples.
  result = "begin immediate;\n"
  for row in rows:
    result.add(insertStatement("ambient_samples", ambientColumns,
      ambientValues(row)) & "\n")
  result.add("commit;\n")

proc appendAmbientSamplesAt*(path: string;
                             rows: openArray[AmbientSampleRow]): SqliteOutcome =
  ## Path-addressed batch append, for the ambient sampler thread: like the
  ## observation writer, it must not touch the ``ObservationStore`` ref
  ## owned by the daemon thread.
  if rows.len == 0:
    return SqliteOutcome(ok: true, exitCode: 0, output: "", error: "")
  runSqlite(path, ambientBatchStatement(rows))

proc appendBatch*(store: ObservationStore; runs: openArray[RunRow];
                  executions: openArray[ExecutionRow]): bool =
  if not store.captureEnabled:
    return false
  if runs.len == 0 and executions.len == 0:
    return true
  store.execute(batchStatement(runs, executions))

# ---------------------------------------------------------------------------
# Readers. Used by the round-trip gate and by clients reading history.
# ---------------------------------------------------------------------------

proc query(store: ObservationStore; sql: string): seq[seq[string]] =
  if store.isNil or store.status notin {ssOpen}:
    return @[]
  let outcome = runSqlite(store.path, sql)
  if not outcome.ok:
    return @[]
  splitRows(outcome.output)

proc readHosts*(store: ObservationStore): seq[HostRow] =
  let sql = "select " & selectText("host_id") & " || '|' || " &
    selectInt("created_at_unix_millis") & " || '|' || " &
    selectText("last_boot_id") & " from hosts order by host_id;"
  for row in store.query(sql):
    result.add(HostRow(
      hostId: decodeText(row[0]),
      createdAtUnixMillis: parseBiggestInt(row[1]),
      lastBootId: decodeText(row[2])))

proc readHostProfiles*(store: ObservationStore): seq[HostProfileRow] =
  let sql = "select " & [
    selectText("host_id"), selectText("profile_id"),
    selectText("profile_hash"), selectInt("valid_from_unix_millis"),
    selectInt("valid_to_unix_millis"), selectText("cpu_model"),
    selectInt("physical_cores"), selectInt("logical_cores"),
    selectInt("ram_bytes"), selectInt("swap_bytes"), selectText("disk_class"),
    selectText("fs_type"), selectText("arch"), selectText("os"),
    selectText("os_version"), selectText("kernel_version"),
    selectText("virtualization"), selectText("cpu_share_group")
  ].join(" || '|' || ") & " from host_profiles order by host_id, profile_id;"
  for row in store.query(sql):
    result.add(HostProfileRow(
      hostId: decodeText(row[0]),
      profileId: decodeText(row[1]),
      profileHash: decodeText(row[2]),
      validFromUnixMillis: parseBiggestInt(row[3]),
      validToUnixMillis: decodeOptInt(row[4]),
      cpuModel: decodeText(row[5]),
      physicalCores: parseBiggestInt(row[6]),
      logicalCores: parseBiggestInt(row[7]),
      ramBytes: parseBiggestInt(row[8]),
      swapBytes: parseBiggestInt(row[9]),
      diskClass: parseEnum[DiskClass](decodeText(row[10])),
      fsType: decodeText(row[11]),
      arch: decodeText(row[12]),
      os: decodeText(row[13]),
      osVersion: decodeText(row[14]),
      kernelVersion: decodeText(row[15]),
      virtualization: decodeText(row[16]),
      cpuShareGroup: decodeText(row[17])))

proc readRuns*(store: ObservationStore): seq[RunRow] =
  let sql = "select " & [
    selectText("run_id"), selectText("host_id"), selectText("tool"),
    selectText("tool_version"), selectText("invocation_kind"),
    selectInt("started_at_unix_millis"),
    selectInt("finished_at_unix_millis"), selectInt("exit_status"),
    selectText("workspace_id"), selectText("profile"),
    selectText("git_commit"), selectText("git_branch"),
    selectText("capture_completeness"), selectInt("dropped_observations")
  ].join(" || '|' || ") & " from runs order by host_id, run_id;"
  for row in store.query(sql):
    result.add(RunRow(
      runId: decodeText(row[0]),
      hostId: decodeText(row[1]),
      tool: decodeText(row[2]),
      toolVersion: decodeText(row[3]),
      invocationKind: decodeText(row[4]),
      startedAtUnixMillis: parseBiggestInt(row[5]),
      finishedAtUnixMillis: decodeOptInt(row[6]),
      exitStatus: decodeOptInt(row[7]),
      workspaceId: decodeOptText(row[8]),
      profile: decodeOptText(row[9]),
      gitCommit: decodeOptText(row[10]),
      gitBranch: decodeOptText(row[11]),
      captureCompleteness: parseEnum[CaptureCompleteness](decodeText(row[12])),
      droppedObservations: parseBiggestInt(row[13])))

proc readExecutions*(store: ObservationStore): seq[ExecutionRow] =
  let sql = "select " & [
    selectText("execution_id"), selectText("host_id"),
    selectText("host_profile_id"), selectText("run_id"),
    selectText("command_stats_id"), selectInt("lease_id"),
    selectInt("started_at_unix_millis"),
    selectInt("finished_at_unix_millis"), selectInt("duration_millis"),
    selectInt("exit_status"), selectText("termination"),
    selectInt("attempt"), selectText("retry_of"),
    selectInt("peak_rss_bytes"), selectInt("cpu_user_millis"),
    selectInt("cpu_sys_millis"), selectInt("max_processes"),
    selectInt("major_page_faults"), selectInt("io_read_bytes"),
    selectInt("io_write_bytes"), selectText("capture_completeness"),
    selectInt("dropped_observations"), selectInt("owner_uid")
  ].join(" || '|' || ") & " from executions order by host_id, execution_id;"
  for row in store.query(sql):
    result.add(ExecutionRow(
      executionId: decodeText(row[0]),
      hostId: decodeText(row[1]),
      hostProfileId: decodeOptText(row[2]),
      runId: decodeText(row[3]),
      commandStatsId: decodeText(row[4]),
      leaseId: decodeOptInt(row[5]),
      startedAtUnixMillis: parseBiggestInt(row[6]),
      finishedAtUnixMillis: parseBiggestInt(row[7]),
      durationMillis: parseBiggestInt(row[8]),
      exitStatus: parseBiggestInt(row[9]),
      termination: parseEnum[Termination](decodeText(row[10])),
      attempt: parseBiggestInt(row[11]),
      retryOf: decodeOptText(row[12]),
      peakRssBytes: parseBiggestInt(row[13]),
      cpuUserMillis: decodeOptInt(row[14]),
      cpuSysMillis: decodeOptInt(row[15]),
      maxProcesses: parseBiggestInt(row[16]),
      majorPageFaults: parseBiggestInt(row[17]),
      ioReadBytes: decodeOptInt(row[18]),
      ioWriteBytes: decodeOptInt(row[19]),
      captureCompleteness: parseEnum[CaptureCompleteness](decodeText(row[20])),
      droppedObservations: parseBiggestInt(row[21]),
      ownerUid: decodeOptInt(row[22])))

proc readAmbientSamples*(store: ObservationStore): seq[AmbientSampleRow] =
  let sql = "select " & [
    selectText("host_id"), selectInt("sampled_at_unix_millis"),
    selectFloat("cpu_busy_pct"), selectInt("mem_available_bytes"),
    selectFloat("swap_in_rate"), selectFloat("io_queue_depth"),
    selectFloat("load_avg_1m"), selectFloat("self_cpu_pct"),
    selectInt("self_rss_bytes"), selectFloat("foreign_cpu_pct"),
    selectInt("foreign_rss_bytes")
  ].join(" || '|' || ") &
    " from ambient_samples order by host_id, sampled_at_unix_millis;"
  for row in store.query(sql):
    result.add(AmbientSampleRow(
      hostId: decodeText(row[0]),
      sampledAtUnixMillis: parseBiggestInt(row[1]),
      cpuBusyPct: parseFloat(row[2]),
      memAvailableBytes: parseBiggestInt(row[3]),
      swapInRate: parseFloat(row[4]),
      ioQueueDepth: parseFloat(row[5]),
      loadAvg1m: parseFloat(row[6]),
      selfCpuPct: parseFloat(row[7]),
      selfRssBytes: parseBiggestInt(row[8]),
      foreignCpuPct: parseFloat(row[9]),
      foreignRssBytes: parseBiggestInt(row[10])))

proc runStatement*(store: ObservationStore; sql: string): bool =
  ## Runs ``sql`` through the same degrade-never-fail path every spine
  ## write uses. It exists for the extension mechanism (``extensions.nim``),
  ## whose statements are built from a schema the DECLARING PRODUCT owns
  ## and which therefore cannot be spelled out here: RunQuota manages
  ## extension tables and MUST NOT interpret their columns (OS-5).
  store.execute(sql)

proc runQuery*(store: ObservationStore; sql: string): seq[seq[string]] =
  ## The read half of ``runStatement``, with the same reason to exist.
  store.query(sql)

proc readExtensionRegistry*(store: ObservationStore):
    seq[ExtensionRegistryRow] =
  let sql = "select " & [
    selectText("extension_id"), selectInt("schema_version"),
    selectText("owner"), selectText("table_name"),
    selectInt("registered_at_unix_millis")
  ].join(" || '|' || ") & " from extension_registry order by extension_id;"
  for row in store.query(sql):
    result.add(ExtensionRegistryRow(
      extensionId: decodeText(row[0]),
      schemaVersion: parseBiggestInt(row[1]),
      owner: decodeText(row[2]),
      tableName: decodeText(row[3]),
      registeredAtUnixMillis: parseBiggestInt(row[4])))

# ---------------------------------------------------------------------------
# Host identity and versioned hardware profiles (M10)
# ---------------------------------------------------------------------------

proc ensureHostRow*(store: ObservationStore; hostId, lastBootId: string): bool =
  ## Records ``hostId`` as a host of this store, refreshing its boot id.
  ##
  ## The id comes from the machine (``identity.resolveHostIdentity``), not
  ## from the store: a database is a file that gets copied, merged and
  ## thrown away, and a machine that took its identity from whichever
  ## database it happened to open would answer to a different name in each
  ## one. This is the M9 placeholder's replacement, and the reason the
  ## placeholder was wrong for a merged database.
  ##
  ## ``last_boot_id`` is updated in place rather than appended, because
  ## ``hosts`` records the machine and not its restarts; ``executions`` is
  ## the immutable table (OS-3), and this is not it.
  if not store.captureEnabled or hostId.len == 0:
    return false
  store.execute(
    "insert into hosts (host_id, created_at_unix_millis, last_boot_id) " &
    "values (" & encodeText(hostId) & ", " & encodeInt(unixMillisNow()) &
      ", " & encodeText(lastBootId) & ") " &
    "on conflict(host_id) do update set last_boot_id = excluded.last_boot_id;")

proc currentHostProfile*(store: ObservationStore;
                         hostId: string): Option[HostProfileRow] =
  ## The profile that is current for ``hostId`` — the one row whose
  ## ``valid_to`` is still open. Schema version 3 makes "one" a constraint
  ## rather than a hope (``host_profiles_current``).
  for row in store.readHostProfiles():
    if row.hostId == hostId and row.validToUnixMillis.isNone:
      return some(row)
  none(HostProfileRow)

proc hostProfileRow(hostId, profileId: string; hardware: HardwareProfile;
                    validFrom: int64): HostProfileRow =
  HostProfileRow(
    hostId: hostId,
    profileId: profileId,
    profileHash: profileHash(hardware),
    validFromUnixMillis: validFrom,
    validToUnixMillis: none(int64),
    cpuModel: hardware.cpuModel,
    physicalCores: hardware.physicalCores,
    logicalCores: hardware.logicalCores,
    ramBytes: hardware.ramBytes,
    swapBytes: hardware.swapBytes,
    diskClass: hardware.diskClass,
    fsType: hardware.fsType,
    arch: hardware.arch,
    os: hardware.os,
    osVersion: hardware.osVersion,
    kernelVersion: hardware.kernelVersion,
    virtualization: hardware.virtualization,
    cpuShareGroup: hardware.cpuShareGroup)

proc ensureHostProfile*(store: ObservationStore; hostId: string;
                        hardware: HardwareProfile;
                        atUnixMillis = 0'i64): string =
  ## Returns the ``profile_id`` of the profile current for ``hostId``,
  ## opening a new one only if the hardware really changed.
  ##
  ## Unchanged hardware reuses the existing row: the descriptive columns
  ## are hashed and the hash compared, so a restart, a hundred restarts,
  ## or a second daemon on the same store all land on the same row. A
  ## table that grew a row per start would have to be disambiguated by
  ## every join that reads it.
  ##
  ## A change closes the old row at ``now`` and opens the new one at the
  ## same instant, so the two intervals are contiguous and neither
  ## overlaps: an execution has exactly one profile at any time it could
  ## have run. **Existing ``executions`` rows are not touched and MUST NOT
  ## be** — they reference the profile that was current when they ran, and
  ## a machine that gained RAM must not retroactively turn every past
  ## duration into a measurement of hardware that did not exist yet.
  ##
  ## Returns the empty string if the profile could not be established, in
  ## which case the caller writes NULL and says so; capture stays on.
  if not store.captureEnabled or hostId.len == 0:
    return ""
  let now = if atUnixMillis > 0: atUnixMillis else: unixMillisNow()
  let hash = profileHash(hardware)

  let current = store.currentHostProfile(hostId)
  if current.isSome:
    if current.get.profileHash == hash:
      return current.get.profileId
    # `valid_to` may not precede `valid_from`: two daemon starts inside one
    # millisecond would otherwise write an interval that runs backwards.
    let closedAt = max(now, current.get.validFromUnixMillis)
    let successor = hostProfileRow(hostId, opaqueId("profile-"), hardware,
      closedAt)
    # One transaction: a closed profile with no successor would leave the
    # host with no current hardware at all, and an open successor beside an
    # open predecessor is refused by `host_profiles_current` anyway.
    if not store.execute(
        "begin immediate;\n" &
        "update host_profiles set valid_to_unix_millis = " &
          encodeInt(closedAt) & " where host_id = " & encodeText(hostId) &
          " and valid_to_unix_millis is null;\n" &
        insertStatement("host_profiles", hostProfileColumns,
          hostProfileValues(successor)) & "\n" &
        "commit;"):
      # No rollback is issued: every `runSqlite` is its own process and its
      # own connection, so an aborted transaction dies with it. Issuing one
      # would fail with "no transaction is active" and that failure, not
      # being a constraint rejection, would disable capture for a write
      # that already did nothing.
      return ""
    return successor.profileId

  let first = hostProfileRow(hostId, opaqueId("profile-"), hardware, now)
  if not store.insertHostProfile(first):
    return ""
  first.profileId
