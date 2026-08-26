## Domain extensions: product-owned tables joined to the execution spine.
##
## Normative specification:
## ``reprobuild-specs/RunQuota-Observation-Store.md`` §"Domain Extensions",
## and OS-5: *RunQuota manages extension registration, migration, retention
## cascade and merge, and MUST NOT interpret extension columns.*
##
## Everything in this module is MECHANISM. Not one line of it knows what
## any extension column means, and that is not a matter of taste: an
## extension is owned by the product that declares it, so a daemon that
## read one of its columns would have taken a dependency on a schema
## nobody promised it.
##
## The boundary is kept honest structurally, not by review:
##
## * **The only table names here are composed**, from the prefix and the
##   caller's ``extension_id``. A concrete extension table name never
##   appears in RunQuota source, which is the naming rule the registry's
##   own check constraint already enforces (``schema.nim``).
## * **The only column names here are the two SPINE KEY columns** every
##   extension table is keyed on, plus the columns of the registry, which
##   is a spine table. The key is the JOIN TO THE SPINE and is not payload;
##   every payload column name this module ever puts into SQL arrives as a
##   parameter from the caller.
##
## ``tests/unit/t_observation_store_extension_boundary.nim`` asserts both,
## over a source set it discovers by walking rather than by listing, and
## with positive controls: a scanner that finds nothing anywhere agrees
## with every implementation.
##
## Two other rules shape the entry points below.
##
## * **Degrade, never fail (OS-4).** Nothing here raises. Every refusal is
##   a returned value; a store that is not open answers "unavailable".
## * **A version that cannot be stored is REFUSED, never approximated.** A
##   client declaring a schema version this database has no route to would
##   otherwise get its rows written into the shape the table happens to
##   have, and the registry would then claim a version the table does not
##   carry. That is the extension-level form of the refusal the spine
##   already makes at ``openObservationStore``.

import std/[options, strutils]

import ./ids, ./schema, ./sqlite_cli, ./store, ./types

const
  extensionTablePrefix* = "ext_"
    ## The naming rule, in the one place it is composed. ``schema.nim``
    ## states the same rule as a check constraint on the registry, so a
    ## row naming a table any other way is unstorable.

  keyHostColumn* = "host_id"
  keyExecutionColumn* = "execution_id"
    ## The two columns an extension table MUST be keyed on, and the ONLY
    ## column names this module is allowed to write down. They are the
    ## join to the spine, not extension payload.

  maxIdentifierLength* = 64

  extensionShapeConstraint* = "rq_extension_shape"
    ## The name SQLite reports when an extension table fails the shape
    ## check. It is how a refused SHAPE is told apart from a migration step
    ## that failed to run at all.

type
  ExtensionDeclaration* = object
    ## What a client says about its own extension. ``migrations[i]`` takes
    ## the extension's table from version ``i`` to version ``i + 1``, so
    ## ``migrations[0]`` is the ``create table`` and the ladder is
    ## forward-only exactly as the spine's is.
    ##
    ## The ladder is what makes a declared version STORABLE. A client that
    ## declares version N and carries fewer than N steps has named a
    ## version this database has no route to, and is refused.
    extensionId*: string
    owner*: string
    schemaVersion*: int64
    migrations*: seq[string]

  ExtensionOutcome* = enum
    ## The result of declaring an extension. Four acceptances and five
    ## refusals, distinguished because "refused" and "accepted an older
    ## client" must never be told apart by their side effects alone.
    eoCreated = "created"
    eoUpToDate = "up-to-date"
    eoMigrated = "migrated"
    eoAcceptedOlder = "accepted-older"
    eoUnavailable = "unavailable"
    eoRefusedIdentifier = "refused-identifier"
    eoRefusedUnstorableVersion = "refused-unstorable-version"
    eoRefusedShape = "refused-shape"
    eoRefusedMigrationFailed = "refused-migration-failed"
    eoRefusedOwner = "refused-owner"

  ExtensionWrite* = enum
    ## The result of writing one extension row.
    ewWritten = "written"
    ewUnavailable = "unavailable"
    ewNotRegistered = "not-registered"
    ewRefusedUnstorableVersion = "refused-unstorable-version"
    ewRefusedRow = "refused-row"
    ewRejected = "rejected"

  ExtensionValueKind* = enum
    evNull, evText, evInt, evReal

  ExtensionValue* = object
    ## One opaque cell. RunQuota knows the four SQL storage classes
    ## because it has to write a literal; it knows nothing about what the
    ## value means.
    case kind*: ExtensionValueKind
    of evNull: discard
    of evText: text*: string
    of evInt: number*: int64
    of evReal: real*: float64

  ExtensionRow* = object
    ## One row of an extension table: the spine key, and a payload the
    ## caller names.
    hostId*: string
    executionId*: string
    columns*: seq[string]
    values*: seq[ExtensionValue]

  DoomedKind* = enum
    dkStartedBefore = "started-before"
    dkBeyondNewest = "beyond-newest"

  DoomedExecutions* = object
    ## WHICH executions a pass is about, as a value.
    ##
    ## M12 had one shape and spelled it as an ``int64`` cutoff. M15's
    ## row-count bound cannot be spelled that way at all: with N rows to
    ## keep, whether a given row is doomed depends on how many others there
    ## are, so there is no timestamp that expresses it. Making the doomed
    ## set a value keeps ONE cascade — the registry-driven one below — for
    ## both bounds, instead of a second copy of it that could drift.
    ##
    ## RunQuota composes every predicate here. A caller supplies a number,
    ## never a fragment of SQL.
    case kind*: DoomedKind
    of dkStartedBefore:
      cutoffUnixMillis*: int64
    of dkBeyondNewest:
      keepNewest*: int64

  PruneOutcome* = object
    ## What a retention pass removed. The extension figure is reported
    ## separately from the spine figure because "the cascade ran" and "the
    ## cascade removed anything" are different claims.
    pruned*: bool
    executionsRemoved*: int64
    extensionRowsRemoved*: int64
    carriedRowsRemoved*: int64
      ## Rows in the merge quarantine that went with their parent. Counted
      ## apart from ``extensionRowsRemoved`` because they are rows of a
      ## schema this database does not have, and pooling the two figures
      ## would report a cascade into tables that do not exist here.
    extensionsCascaded*: seq[string]
    detail*: string

proc extNull*(): ExtensionValue = ExtensionValue(kind: evNull)
proc extText*(value: string): ExtensionValue =
  ExtensionValue(kind: evText, text: value)
proc extInt*(value: int64): ExtensionValue =
  ExtensionValue(kind: evInt, number: value)
proc extReal*(value: float64): ExtensionValue =
  ExtensionValue(kind: evReal, real: value)

proc extensionTableName*(extensionId: string): string =
  ## The naming rule, composed. This is the only place in RunQuota where
  ## an extension table name comes into existence.
  extensionTablePrefix & extensionId

proc isStorableIdentifier*(name: string): bool =
  ## Whether ``name`` may be interpolated into SQL as an identifier.
  ##
  ## This is a check on the SHAPE of a name, not on its meaning: RunQuota
  ## builds these statements by concatenation, so a name that is not a
  ## bare lowercase identifier is refused rather than quoted. Refusing is
  ## the honest answer — a client that wants a column named with a space
  ## in it is asking RunQuota to make a decision about its schema.
  if name.len == 0 or name.len > maxIdentifierLength:
    return false
  if name[0] notin {'a' .. 'z'}:
    return false
  for c in name:
    if c notin {'a' .. 'z', '0' .. '9', '_'}:
      return false
  true

proc encodeValue(value: ExtensionValue): string =
  case value.kind
  of evNull: "null"
  of evText: encodeText(value.text)
  of evInt: encodeInt(value.number)
  of evReal: encodeFloat(value.real)

# ---------------------------------------------------------------------------
# Statement builders. Exported so that what RunQuota emits against an
# extension table can be inspected directly, rather than inferred from the
# source that builds it.
# ---------------------------------------------------------------------------

proc extensionShapeGate*(tableName: string): string =
  ## SQL that ABORTS unless ``tableName`` has the shape the specification
  ## requires: keyed on the two spine key columns, with a foreign key to
  ## ``executions``.
  ##
  ## It is written as a constraint violation rather than as a query whose
  ## result is inspected afterwards, so that it can run INSIDE the same
  ## transaction as the ``create table`` it is checking. A shape check that
  ## ran after the commit would have to drop a table it had already
  ## published, and a reader between the two would see an extension table
  ## RunQuota had already decided was invalid.
  ##
  ## The constraint is NAMED, because the name is what tells a refused
  ## shape apart from a migration step that simply did not run: SQLite
  ## reports an unnamed check by its expression, and "CHECK constraint
  ## failed: ok = 1" says nothing about which of the two happened.
  let quoted = encodeText(tableName)
  "create temp table rq_extension_shape_gate (ok integer constraint " &
    extensionShapeConstraint & " check (ok = 1));\n" &
  "insert into rq_extension_shape_gate select case when (select count(*) " &
    "from pragma_table_info(" & quoted & ") where name in (" &
    encodeText(keyHostColumn) & ", " & encodeText(keyExecutionColumn) &
    ") and pk > 0) = 2 then 1 else 0 end;\n" &
  "insert into rq_extension_shape_gate select case when (select " &
    "count(distinct id) from pragma_foreign_key_list(" & quoted &
    ") where \"table\" = 'executions') >= 1 then 1 else 0 end;\n"

proc extensionInsertStatement*(tableName: string; row: ExtensionRow): string =
  ## The insert for one extension row. The key columns are RunQuota's; every
  ## other column name in the result arrived in ``row.columns``.
  var columns = @[keyHostColumn, keyExecutionColumn]
  var values = @[encodeText(row.hostId), encodeText(row.executionId)]
  for i, name in row.columns:
    columns.add(name)
    values.add(encodeValue(row.values[i]))
  "insert into " & tableName & " (" & columns.join(", ") & ") values (" &
    values.join(", ") & ");"

proc startedBefore*(cutoffUnixMillis: int64): DoomedExecutions =
  DoomedExecutions(kind: dkStartedBefore, cutoffUnixMillis: cutoffUnixMillis)

proc beyondNewest*(keepNewest: int64): DoomedExecutions =
  DoomedExecutions(kind: dkBeyondNewest, keepNewest: max(0'i64, keepNewest))

proc doomedExecutionsClause*(hostId: string;
                             doomed: DoomedExecutions): string =
  ## The ``where`` clause naming the doomed executions of one host.
  ##
  ## Every column in it belongs to ``executions``, which is a spine table
  ## RunQuota owns; nothing here knows an extension column. The row-count
  ## arm's ordering is TOTAL — ``started_at`` then the execution id — so
  ## two hosts with the same timestamps do not get different answers on
  ## different runs, which a merge asserting order-independence would
  ## otherwise see as a difference.
  let host = keyHostColumn & " = " & encodeText(hostId)
  case doomed.kind
  of dkStartedBefore:
    host & " and started_at_unix_millis < " &
      encodeInt(doomed.cutoffUnixMillis)
  of dkBeyondNewest:
    host & " and " & keyExecutionColumn & " not in (select " &
      keyExecutionColumn & " from executions where " & host &
      " order by started_at_unix_millis desc, " & keyExecutionColumn &
      " desc limit " & encodeInt(doomed.keepNewest) & ")"

proc extensionCascadeWhere*(tableName, hostId: string;
                            doomed: DoomedExecutions): string =
  ## The retention cascade for one extension table.
  ##
  ## It selects the doomed rows BY THE SPINE KEY and by nothing else: the
  ## predicate lives entirely on ``executions``, so retention is decided by
  ## the spine and merely applied here. An extension column appearing in
  ## this statement would mean RunQuota had an opinion about which of a
  ## product's rows are worth keeping.
  "delete from " & tableName & " where (" & keyHostColumn & ", " &
    keyExecutionColumn & ") in (select " & keyHostColumn & ", " &
    keyExecutionColumn & " from executions where " &
    doomedExecutionsClause(hostId, doomed) & ");"

proc extensionCascadeStatement*(tableName, hostId: string;
                                startedBeforeUnixMillis: int64): string =
  ## The age-bounded cascade, which is the shape M12 shipped.
  extensionCascadeWhere(tableName, hostId,
    startedBefore(startedBeforeUnixMillis))

proc carriedCascadeStatement*(hostId: string;
                              doomed: DoomedExecutions): string =
  ## The same cascade, into the merge quarantine.
  ##
  ## Carried rows are facts about an execution whose schema this database
  ## does not have, and retention is not excused from them: leaving them
  ## behind would orphan rows no query can reach and no later pass would
  ## find, because the pass is driven by the parent.
  "delete from " & carriedExtensionTable & " where (" & keyHostColumn &
    ", " & keyExecutionColumn & ") in (select " & keyHostColumn & ", " &
    keyExecutionColumn & " from executions where " &
    doomedExecutionsClause(hostId, doomed) & ");"

# ---------------------------------------------------------------------------
# Registration and migration
# ---------------------------------------------------------------------------

proc extensionRegistryEntry*(store: ObservationStore;
    extensionId: string): Option[ExtensionRegistryRow] =
  ## What the DATABASE says about this extension, which is the only thing
  ## that decides what it can store.
  for row in store.readExtensionRegistry():
    if row.extensionId == extensionId:
      return some(row)
  none(ExtensionRegistryRow)

proc extensionTableExists*(store: ObservationStore;
                           tableName: string): bool =
  let rows = store.runQuery(
    "select count(*) from sqlite_master where type = 'table' and name = " &
      encodeText(tableName) & ";")
  rows.len == 1 and rows[0].len == 1 and rows[0][0].strip() == "1"

proc ladderCovers(declaration: ExtensionDeclaration; upTo: int64): bool =
  ## Whether the declaration carries the DDL to reach version ``upTo``.
  ## This is what "a version this database can store" means: a version is
  ## storable exactly when there is a step for every version below it.
  upTo >= 1 and declaration.migrations.len >= int(upTo)

proc declareExtension*(store: ObservationStore;
                       declaration: ExtensionDeclaration): ExtensionOutcome =
  ## Registers ``declaration``, creating or migrating its table as needed,
  ## and returns what happened.
  ##
  ## The version comparison is against the REGISTRY, which records what
  ## this database actually carries:
  ##
  ## * equal — nothing to do;
  ## * older — accepted, and the table is left alone. An older client
  ##   writes the columns it knows and the rest take their declared
  ##   defaults, which is well defined; refusing it would make every schema
  ##   bump a flag day for every client on the host.
  ## * newer, with the steps to get there — the extension migrates, ON ITS
  ##   OWN, with the spine untouched;
  ## * newer, without them — REFUSED. There is no route to that version, so
  ##   the alternative is writing rows into a shape that is not the one the
  ##   client described while the registry claims otherwise.
  if not store.captureEnabled:
    return eoUnavailable
  if not isStorableIdentifier(declaration.extensionId):
    return eoRefusedIdentifier
  if declaration.schemaVersion < 1:
    return eoRefusedUnstorableVersion

  let tableName = extensionTableName(declaration.extensionId)
  let existing = store.extensionRegistryEntry(declaration.extensionId)

  if existing.isNone:
    if not ladderCovers(declaration, declaration.schemaVersion):
      return eoRefusedUnstorableVersion
    var sql = "begin immediate;\n"
    for step in 0 ..< int(declaration.schemaVersion):
      sql.add(declaration.migrations[step] & "\n")
    sql.add(extensionShapeGate(tableName))
    sql.add("insert into extension_registry (extension_id, schema_version, " &
      "owner, table_name, registered_at_unix_millis) values (" &
      encodeText(declaration.extensionId) & ", " &
      encodeInt(declaration.schemaVersion) & ", " &
      encodeText(declaration.owner) & ", " & encodeText(tableName) & ", " &
      encodeInt(unixMillisNow()) & ");\n")
    sql.add("commit;\n")
    if not store.runStatement(sql):
      # The shape gate and a failing migration step are told apart by what
      # the store recorded, because they are refusals of different things:
      # one says the client's table is not joinable to the spine, the other
      # says its DDL did not run.
      return if extensionShapeConstraint in store.lastError: eoRefusedShape
             else: eoRefusedMigrationFailed
    return eoCreated

  let registered = existing.get
  # THE OWNER IS WRITTEN ONCE AND CHECKED EVERY TIME AFTER. It was
  # previously written at first registration and never compared again, so a
  # second client declaring the same id under a different owner was
  # silently accepted and wrote into the first one's table -- which is what
  # a forked copy of a shared extension constant looks like from here, and
  # exactly what OS-8 asks two runners NOT to do accidentally. Two runners
  # that legitimately share one generic extension share one owner constant
  # precisely so that this comparison holds for them; a runner that spelled
  # its own would be the case this refuses.
  #
  # REFUSED BEFORE ANYTHING RUNS, so the store is left exactly as it was:
  # a declaration that fails must roll back to the state before it.
  if declaration.owner != registered.owner:
    return eoRefusedOwner
  if not store.extensionTableExists(tableName):
    # The registry claims a table that is not there. Creating it now would
    # mean guessing which of the client's steps the missing table was built
    # from, and the honest answer is that this database cannot store the
    # extension at all.
    return eoRefusedShape
  if declaration.schemaVersion == registered.schemaVersion:
    return eoUpToDate
  if declaration.schemaVersion < registered.schemaVersion:
    return eoAcceptedOlder
  if not ladderCovers(declaration, declaration.schemaVersion):
    return eoRefusedUnstorableVersion

  var sql = "begin immediate;\n"
  for step in int(registered.schemaVersion) ..< int(declaration.schemaVersion):
    sql.add(declaration.migrations[step] & "\n")
  sql.add("update extension_registry set schema_version = " &
    encodeInt(declaration.schemaVersion) & " where extension_id = " &
    encodeText(declaration.extensionId) & ";\n")
  sql.add(extensionShapeGate(tableName))
  sql.add("commit;\n")
  if not store.runStatement(sql):
    return if extensionShapeConstraint in store.lastError: eoRefusedShape
           else: eoRefusedMigrationFailed
  eoMigrated

# ---------------------------------------------------------------------------
# Writing and reading extension rows
# ---------------------------------------------------------------------------

proc admitExtensionRow*(store: ObservationStore;
                        declaration: ExtensionDeclaration;
                        row: ExtensionRow):
    tuple[outcome: ExtensionWrite, statement: string] =
  ## Every check ``insertExtensionRow`` makes, WITHOUT executing anything,
  ## returning the statement that would be run.
  ##
  ## Split out for the write path M17 needs and for no other reason. The
  ## background observation writer is PATH-ADDRESSED — it must not touch
  ## the ``ObservationStore`` ref owned by the daemon thread — so the
  ## checks, every one of which needs the registry, have to happen on the
  ## daemon thread while the statement is executed later by the writer.
  ## Splitting is the only way to keep ONE copy of those checks; a second
  ## validating path is a second thing to keep correct, and the one that
  ## drifted would be the one nothing tested.
  ##
  ## A client declaring a version NEWER than the registry carries is
  ## refused here and not silently written: its row is shaped for a table
  ## this database does not have, so every column the newer version added
  ## would be dropped on the floor and the row would read afterwards as a
  ## complete observation of an older schema. An OLDER or equal declaration
  ## is written — the columns it does not know take their declared
  ## defaults, which is the whole point of a forward-only ladder.
  if not store.captureEnabled:
    return (ewUnavailable, "")
  if not isStorableIdentifier(declaration.extensionId):
    return (ewRefusedRow, "")
  if row.columns.len != row.values.len:
    return (ewRefusedRow, "")
  for name in row.columns:
    if not isStorableIdentifier(name) or
        name == keyHostColumn or name == keyExecutionColumn:
      return (ewRefusedRow, "")
  let existing = store.extensionRegistryEntry(declaration.extensionId)
  if existing.isNone:
    return (ewNotRegistered, "")
  if declaration.schemaVersion > existing.get.schemaVersion:
    return (ewRefusedUnstorableVersion, "")
  let tableName = extensionTableName(declaration.extensionId)
  (ewWritten, extensionInsertStatement(tableName, row))

proc insertExtensionRow*(store: ObservationStore;
                         declaration: ExtensionDeclaration;
                         row: ExtensionRow): ExtensionWrite =
  ## Writes one extension row on behalf of a client declaring
  ## ``declaration.schemaVersion``. Admission and execution, in the
  ## synchronous shape M12 shipped.
  let admitted = store.admitExtensionRow(declaration, row)
  if admitted.outcome != ewWritten:
    return admitted.outcome
  if not store.runStatement(admitted.statement):
    return ewRejected
  ewWritten

proc readExtensionColumns*(store: ObservationStore; extensionId: string;
                           columns: openArray[string]): seq[seq[string]] =
  ## Reads ``columns`` out of an extension table on the caller's
  ## instruction, ordered by the spine key.
  ##
  ## Every value comes back as the text SQLite renders it as, and SQL NULL
  ## comes back as ``nullMarker`` so that it stays distinguishable from the
  ## empty string. RunQuota carries the value; it does not parse it, and it
  ## does not know which of these columns is a duration and which is a name.
  if not isStorableIdentifier(extensionId):
    return @[]
  var selected: seq[string] = @[]
  for name in columns:
    if not isStorableIdentifier(name):
      return @[]
    selected.add(selectText(name))
  if selected.len == 0:
    return @[]
  for row in store.runQuery("select " & selected.join(" || '|' || ") &
      " from " & extensionTableName(extensionId) & " order by " &
      keyHostColumn & ", " & keyExecutionColumn & ";"):
    var decoded: seq[string] = @[]
    for field in row:
      decoded.add(if field.isNullField: nullMarker else: decodeText(field))
    result.add(decoded)

proc extensionRowCount*(store: ObservationStore; extensionId: string): int64 =
  ## How many rows the extension table holds, or ``-1`` if it cannot be
  ## counted. Retention asserts against this, so "the cascade removed the
  ## rows" can be told apart from "there were never any rows".
  if not isStorableIdentifier(extensionId):
    return -1
  let rows = store.runQuery("select count(*) from " &
    extensionTableName(extensionId) & ";")
  if rows.len != 1 or rows[0].len != 1:
    return -1
  try:
    parseBiggestInt(rows[0][0].strip())
  except ValueError:
    -1

# ---------------------------------------------------------------------------
# Retention cascade
# ---------------------------------------------------------------------------

proc pruneExecutions*(store: ObservationStore; hostId: string;
                      doomed: DoomedExecutions): PruneOutcome =
  ## Removes every execution of ``hostId`` in the doomed set, and every
  ## extension row and carried row that belonged to one.
  ##
  ## THE CASCADE IS DRIVEN BY THE REGISTRY, not by a list in this file. An
  ## extension RunQuota has never heard of is still pruned, because the
  ## registry is what says which tables exist; a hardcoded list would prune
  ## the extensions somebody remembered and orphan the rest.
  ##
  ## It is ONE transaction. A cascade that removed the spine rows and then
  ## crashed would leave extension rows referring to executions that no
  ## longer exist — rows no query can reach and no later pass would find,
  ## because the pass is driven by the parent.
  result = PruneOutcome(pruned: false, executionsRemoved: 0,
                        extensionRowsRemoved: 0, carriedRowsRemoved: 0,
                        extensionsCascaded: @[], detail: "")
  if not store.captureEnabled:
    result.detail = "store is not open"
    return
  if hostId.len == 0:
    result.detail = "no host"
    return

  let clause = doomedExecutionsClause(hostId, doomed)
  let membership = "(" & keyHostColumn & ", " & keyExecutionColumn &
    ") in (select " & keyHostColumn & ", " & keyExecutionColumn &
    " from executions where " & clause & ")"

  let counted = store.runQuery(
    "select count(*) from executions where " & clause & ";")
  if counted.len == 1 and counted[0].len == 1:
    try:
      result.executionsRemoved = parseBiggestInt(counted[0][0].strip())
    except ValueError:
      discard

  var sql = "begin immediate;\n"
  for entry in store.readExtensionRegistry():
    if not isStorableIdentifier(entry.extensionId):
      continue
    let tableName = extensionTableName(entry.extensionId)
    # A registry row whose table was never created is not an error here:
    # there is nothing of that extension to cascade into. Skipping it is
    # what keeps one absent table from failing the whole pass.
    if not store.extensionTableExists(tableName):
      continue
    let doomedRows = store.runQuery("select count(*) from " & tableName &
      " where " & membership & ";")
    if doomedRows.len == 1 and doomedRows[0].len == 1:
      try:
        result.extensionRowsRemoved +=
          parseBiggestInt(doomedRows[0][0].strip())
      except ValueError:
        discard
    result.extensionsCascaded.add(entry.extensionId)
    sql.add(extensionCascadeWhere(tableName, hostId, doomed) & "\n")

  let doomedCarried = store.runQuery("select count(*) from " &
    carriedExtensionTable & " where " & membership & ";")
  if doomedCarried.len == 1 and doomedCarried[0].len == 1:
    try:
      result.carriedRowsRemoved = parseBiggestInt(doomedCarried[0][0].strip())
    except ValueError:
      discard
  sql.add(carriedCascadeStatement(hostId, doomed) & "\n")

  sql.add("delete from executions where " & clause & ";\n")
  sql.add("commit;\n")

  if not store.runStatement(sql):
    result.executionsRemoved = 0
    result.extensionRowsRemoved = 0
    result.carriedRowsRemoved = 0
    result.detail = store.lastError
    return
  result.pruned = true

proc pruneExecutionsBefore*(store: ObservationStore; hostId: string;
                            startedBeforeUnixMillis: int64): PruneOutcome =
  ## The age-bounded pass, which is the shape M12 shipped.
  store.pruneExecutions(hostId, startedBefore(startedBeforeUnixMillis))
