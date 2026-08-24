## Merge: the append-only union of two observation stores.
##
## Normative specification:
## ``reprobuild-specs/RunQuota-Observation-Store.md`` §"Merge And The
## Company-Wide Knowledge Base", and OS-7. It is also the fourth and last
## limb of OS-5 — RunQuota manages extension registration, migration,
## retention cascade and MERGE — the three others having landed in M12.
##
## Every row is an immutable fact about a completed event (OS-3), so the
## merge is a join-semilattice over sets of rows and has NO conflict
## resolution: two facts with the same key are the same fact. That is what
## makes ``insert or ignore`` the whole algorithm rather than a shortcut,
## and it is also the assumption the algorithm rests on — a source that
## carried a DIFFERENT row under a key the destination already holds would
## be a source that had violated immutability upstream, and this module
## keeps the destination's copy rather than inventing a resolution rule for
## a case the store's own trigger forbids.
##
## FOUR RULES SHAPE EVERYTHING BELOW.
##
## * **A merge writes nothing that depends on WHEN it ran.** This is the
##   rule with teeth, and it is the one a first implementation gets wrong:
##   the obvious ``carried_at`` column on a carried row is enough to make
##   "two sources in either order" produce two different databases, because
##   the row carried first is stamped earlier in one order and later in the
##   other. There is no clock in this file. Order-independence is not a
##   property one asserts about a merge; it is a property one refrains from
##   destroying.
## * **Extension rows the receiver does not know are CARRIED, never
##   dropped.** "Does not know" is two cases and both are here: an
##   ``extension_id`` with no registry row at all, and a registered one
##   whose ``schema_version`` in the source is NEWER than the receiver
##   carries. The second is the dangerous one — the columns line up well
##   enough that a merge could insert the subset it recognises and lose the
##   rest silently, leaving a row that reads afterwards as a complete
##   observation of an older schema. That is precisely the "quietly lossy"
##   failure the specification names.
## * **Carried rows are UNQUERYABLE, structurally.** They land in a spine
##   table whose ``queryable`` column carries a check constraint pinning it
##   to zero, so no row anywhere can claim otherwise — not even one written
##   by a client reaching past this library into ``sqlite3``. There is no
##   read path from ``readExtensionColumns`` or from ``query.nim`` into
##   that table.
## * **A merge without the host and hardware dimension is REFUSED**, before
##   anything is written. OS-6: durations pooled across unknown hardware
##   are not a weaker statistic, they are a misleading one. The check is on
##   the SOURCE, because the destination's dimension is its own business
##   and the rows arriving are the ones that would be unqualifiable.
##
## No daemon is involved on either side. The destination is a file this
## process opened and the source is a file it reads; ``runquotad`` is the
## only sanctioned reader of a LIVE store, and a merge is an offline
## operation over stores nobody is serving.
##
## The registry itself is NOT merged. Copying a source's registry row for
## an extension the receiver does not know would make the receiver claim to
## know it, which is exactly the claim the carried-row quarantine exists to
## avoid making.

import std/[algorithm, options, os, strutils]

import ./canonical, ./extensions, ./schema, ./sqlite_cli, ./store

type
  MergeOutcome* = enum
    moMerged = "merged"
    moUnavailable = "unavailable"
    moSourceUnreadable = "source-unreadable"
    moRefusedNewerSchema = "refused-newer-schema"
    moRefusedNoHostDimension = "refused-no-host-dimension"
    moFailed = "failed"

  MergeReport* = object
    outcome*: MergeOutcome
    detail*: string
    hostsAdded*: int64
    hostProfilesAdded*: int64
    runsAdded*: int64
    executionsAdded*: int64
    ambientSamplesAdded*: int64
    extensionRowsAdded*: int64
    carriedRowsAdded*: int64
    knownExtensions*: seq[string]
      ## Source extensions the receiver knows at a version it can store, so
      ## their rows went into the real table and stayed queryable.
    carriedExtensions*: seq[string]
      ## Source extensions the receiver does not know, or knows only at an
      ## older version. Their rows are in quarantine.

const
  mergedSpineTables* = [
    "hosts", "host_profiles", "runs", "executions", "ambient_samples"]
    ## In foreign-key order, parents first. ``extension_registry`` is
    ## absent by decision, not by omission — see the module comment.

proc scalarOf(path, sql: string): int64 =
  let outcome = runSqlite(path, sql)
  if not outcome.ok:
    return -1
  try:
    parseBiggestInt(outcome.output.strip())
  except ValueError:
    -1

proc linesOf(path, sql: string): seq[string] =
  let outcome = runSqlite(path, sql)
  if not outcome.ok:
    return @[]
  for line in outcome.output.splitLines():
    if line.len > 0:
      result.add(line)

proc tableExistsIn(path, table: string): bool =
  scalarOf(path, "select count(*) from sqlite_master where type = 'table' " &
    "and name = " & encodeText(table) & ";") == 1

proc columnsOf(path, table: string): seq[string] =
  linesOf(path, "select name from pragma_table_info(" & encodeText(table) &
    ") order by cid;")

proc sharedColumns(destination, source: seq[string]): seq[string] =
  ## The columns both sides have, in the DESTINATION's order. A source
  ## written by an older RunQuota is missing the columns later migrations
  ## added; those take their declared defaults, exactly as they do for an
  ## older client of an extension.
  for column in destination:
    if column in source:
      result.add(column)

proc hostDimensionDetail*(sourcePath: string): string =
  ## Empty means the source carries the host and hardware dimension.
  ## Anything else is the reason it does not, and is the text of the
  ## refusal.
  ##
  ## Three distinct failures, because they are three distinct ways to lose
  ## OS-6 and a reader of the refusal needs to know which one happened.
  for table in mergedSpineTables:
    if not tableExistsIn(sourcePath, table):
      return "source has no " & table & " table"

  let danglingHosts = scalarOf(sourcePath,
    "select (select count(*) from executions where host_id not in " &
    "(select host_id from hosts)) + (select count(*) from runs where " &
    "host_id not in (select host_id from hosts)) + (select count(*) from " &
    "host_profiles where host_id not in (select host_id from hosts)) + " &
    "(select count(*) from ambient_samples where host_id not in " &
    "(select host_id from hosts));")
  if danglingHosts < 0:
    return "source could not be read"
  if danglingHosts > 0:
    return $danglingHosts & " source row(s) name a host with no hosts row"

  let unqualified = scalarOf(sourcePath,
    "select count(*) from executions where host_profile_id is null;")
  if unqualified < 0:
    return "source could not be read"
  if unqualified > 0:
    return $unqualified & " source execution(s) carry no hardware profile"

  let danglingProfiles = scalarOf(sourcePath,
    "select count(*) from executions e where not exists (select 1 from " &
    "host_profiles p where p.host_id = e.host_id and p.profile_id = " &
    "e.host_profile_id);")
  if danglingProfiles < 0:
    return "source could not be read"
  if danglingProfiles > 0:
    return $danglingProfiles &
      " source execution(s) name a hardware profile that is not there"
  ""

proc sourceExtensionTables*(sourcePath: string): seq[string] =
  ## Every extension table the SOURCE holds, discovered from its schema
  ## rather than from its registry.
  ##
  ## The registry is the authority on what an extension IS; it is not the
  ## authority on what a file contains. A source whose registry row went
  ## missing still holds rows somebody's product wrote, and dropping them
  ## because a bookkeeping row was absent is the lossy behaviour this
  ## milestone exists to forbid. ``substr`` rather than ``like``: ``_`` is
  ## a LIKE wildcard, so ``like 'ext_%'`` would also match ``extra_...``.
  result = linesOf(sourcePath,
    "select name from sqlite_master where type = 'table' and substr(name, " &
    "1, " & $extensionTablePrefix.len & ") = " &
    encodeText(extensionTablePrefix) & " order by name;")
  result.sort()

proc sourceExtensionVersion(sourcePath, extensionId: string): int64 =
  ## What the SOURCE says its extension's schema version is. Zero when the
  ## source has no registry row for it — an unknown version is not version
  ## one, and a carried row records the number the source actually claimed.
  let value = scalarOf(sourcePath,
    "select coalesce((select schema_version from extension_registry where " &
    "extension_id = " & encodeText(extensionId) & "), 0);")
  if value < 0: 0 else: value

proc carriedPayloadExpression*(columns: openArray[string]): string =
  ## The opaque rendering of one source extension row.
  ##
  ## It is the same encoding ``canonical.nim`` uses, with the column NAME
  ## in front of each cell, so a carried row records what the source called
  ## its columns as well as what was in them — which is the difference
  ## between quarantining a row and quarantining a tuple nobody can ever
  ## interpret again. Every name here arrived from ``pragma_table_info`` on
  ## the source database; not one of them is written down in RunQuota.
  var parts: seq[string] = @[]
  for column in columns:
    parts.add(encodeText(column) & " || '=' || " &
      canonicalValueExpression(column))
  parts.join(" || '" & canonicalFieldSeparator & "' || ")

proc mergeObservationStore*(destination: ObservationStore;
                            sourcePath: string): MergeReport =
  ## Unions ``sourcePath`` into ``destination``. Never raises.
  result = MergeReport(outcome: moFailed, detail: "", hostsAdded: 0,
    hostProfilesAdded: 0, runsAdded: 0, executionsAdded: 0,
    ambientSamplesAdded: 0, extensionRowsAdded: 0, carriedRowsAdded: 0,
    knownExtensions: @[], carriedExtensions: @[])

  if not destination.captureEnabled:
    result.outcome = moUnavailable
    result.detail = "destination store is not open"
    return
  if not sqliteToolAvailable():
    result.outcome = moUnavailable
    result.detail = "the '" & sqliteTool & "' tool is not on PATH"
    return
  if not fileExists(sourcePath):
    result.outcome = moSourceUnreadable
    result.detail = "no such database: " & sourcePath
    return

  let integrity = runSqlite(sourcePath, "pragma quick_check;")
  if not integrity.ok or integrity.output.strip() != "ok":
    result.outcome = moSourceUnreadable
    result.detail = "source is not a readable database"
    return

  let sourceVersion = scalarOf(sourcePath, "pragma user_version;")
  if sourceVersion < 0:
    result.outcome = moSourceUnreadable
    result.detail = "source schema version is unreadable"
    return
  if sourceVersion > spineSchemaVersion:
    # The same refusal ``openObservationStore`` makes, for the same reason:
    # a schema this build does not understand cannot be read correctly, and
    # reading it anyway would silently drop whatever the newer version
    # added.
    result.outcome = moRefusedNewerSchema
    result.detail = "source is at schema " & $sourceVersion &
      ", this build understands at most " & $spineSchemaVersion
    return

  let dimension = hostDimensionDetail(sourcePath)
  if dimension.len > 0:
    # REFUSED BEFORE ANYTHING IS WRITTEN. A partial merge that stopped on
    # the first unqualifiable row would have already pooled the rows before
    # it, and OS-6 is about the aggregate rather than about the row.
    result.outcome = moRefusedNoHostDimension
    result.detail = dimension
    return

  var before: seq[int64] = @[]
  for table in mergedSpineTables:
    before.add(scalarOf(destination.path, "select count(*) from " & table & ";"))
  let carriedBefore = scalarOf(destination.path,
    "select count(*) from " & carriedExtensionTable & ";")

  # ATTACH cannot run inside a transaction, so the batch is attach, one
  # transaction, detach. Everything that writes is inside the transaction:
  # a merge that failed halfway would otherwise leave the destination
  # holding executions whose extension rows never arrived.
  var sql = "attach database " & encodeText(sourcePath) & " as src;\n"
  sql.add("begin immediate;\n")
  for table in mergedSpineTables:
    let columns = sharedColumns(columnsOf(destination.path, table),
                                columnsOf(sourcePath, table))
    if columns.len == 0:
      result.detail = "no shared columns in " & table
      return
    sql.add("insert or ignore into main." & table & " (" &
      columns.join(", ") & ") select " & columns.join(", ") & " from src." &
      table & ";\n")

  var extensionRowsBefore = 0'i64
  for table in sourceExtensionTables(sourcePath):
    let extensionId = table[extensionTablePrefix.len .. ^1]
    if not isStorableIdentifier(extensionId):
      continue
    let sourceColumns = columnsOf(sourcePath, table)
    if keyHostColumn notin sourceColumns or
        keyExecutionColumn notin sourceColumns:
      # Not joinable to the spine, so there is nothing to attach it to.
      # This is the shape the registration path already refuses.
      continue
    let version = sourceExtensionVersion(sourcePath, extensionId)
    let known = destination.extensionRegistryEntry(extensionId)
    let receiverKnows = known.isSome and known.get.schemaVersion >= version and
      destination.extensionTableExists(table)
    if receiverKnows:
      let columns = sharedColumns(columnsOf(destination.path, table),
                                  sourceColumns)
      if columns.len == 0:
        continue
      extensionRowsBefore += scalarOf(destination.path,
        "select count(*) from " & table & ";")
      sql.add("insert or ignore into main." & table & " (" &
        columns.join(", ") & ") select " & columns.join(", ") &
        " from src." & table & ";\n")
      result.knownExtensions.add(extensionId)
    else:
      sql.add("insert or ignore into main." & carriedExtensionTable &
        " (extension_id, schema_version, " & keyHostColumn & ", " &
        keyExecutionColumn & ", payload, queryable) select " &
        encodeText(extensionId) & ", " & encodeInt(version) & ", " &
        keyHostColumn & ", " & keyExecutionColumn & ", " &
        carriedPayloadExpression(sourceColumns) & ", 0 from src." & table &
        ";\n")
      result.carriedExtensions.add(extensionId)
  sql.add("commit;\ndetach database src;\n")

  if not destination.runStatement(sql):
    result.outcome = moFailed
    result.detail = destination.lastError
    return

  for i, table in mergedSpineTables:
    let added = scalarOf(destination.path,
      "select count(*) from " & table & ";") - before[i]
    case table
    of "hosts": result.hostsAdded = added
    of "host_profiles": result.hostProfilesAdded = added
    of "runs": result.runsAdded = added
    of "executions": result.executionsAdded = added
    of "ambient_samples": result.ambientSamplesAdded = added
    else: discard
  result.carriedRowsAdded = scalarOf(destination.path,
    "select count(*) from " & carriedExtensionTable & ";") - carriedBefore
  var extensionRowsAfter = 0'i64
  for extensionId in result.knownExtensions:
    extensionRowsAfter += scalarOf(destination.path,
      "select count(*) from " & extensionTableName(extensionId) & ";")
  result.extensionRowsAdded = extensionRowsAfter - extensionRowsBefore
  result.outcome = moMerged

proc mergeObservationStores*(destinationPath, sourcePath: string): MergeReport =
  ## The same merge, against a destination this call opens itself.
  ##
  ## Merging must be possible with NO LIVE DAEMON on either side, and this
  ## is the entry point that says so in its signature: two paths, no
  ## socket, no rendezvous directory, no lease authority.
  let destination = openObservationStore(destinationPath)
  if not destination.captureEnabled:
    return MergeReport(outcome: moUnavailable, detail: destination.report,
      knownExtensions: @[], carriedExtensions: @[])
  mergeObservationStore(destination, sourcePath)

proc carriedExtensionRows*(store: ObservationStore;
    extensionId: string): seq[string] =
  ## The quarantined payloads for one extension, ordered by the spine key.
  ##
  ## THIS IS NOT A QUERY INTERFACE OVER THEM, and the distinction is the
  ## specification's: carried rows "MUST NOT be queried". What this returns
  ## is the opaque payload text, which is how an operator confirms the rows
  ## are THERE — the evidence that the merge was not lossy. Nothing here
  ## decodes a column, and no aggregate is computed over one.
  if not store.captureEnabled or not isStorableIdentifier(extensionId):
    return @[]
  for row in store.runQuery("select " & selectText("payload") & " from " &
      carriedExtensionTable & " where extension_id = " &
      encodeText(extensionId) & " order by " & keyHostColumn & ", " &
      keyExecutionColumn & ", schema_version;"):
    if row.len == 1:
      result.add(decodeText(row[0]))
