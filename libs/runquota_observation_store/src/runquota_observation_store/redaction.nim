## Export: handing a store across a trust boundary with a redaction policy
## applied, and saying in the artifact which policy that was.
##
## Normative specification:
## ``reprobuild-specs/RunQuota-Observation-Store.md`` §"Merge And The
## Company-Wide Knowledge Base" → "Redaction":
##
## * "Command-line fragments, workspace ids, branch names, and paths
##   disclose project structure."
## * "Export MUST apply a redaction policy, and MUST record which policy
##   was applied."
## * "Redaction status MUST be visible to readers of exported data."
## * "Redaction MUST be applied at export, not at capture. A local store is
##   as trusted as the machine it sits on, and redacting at capture would
##   destroy detail the owner is entitled to."
##
## The policy names are ``CLI/stats.md``'s: ``--redact=default|strict|none``.
##
## ---------------------------------------------------------------------
## THE LAST CLAUSE IS THE DESIGN, AND IT IS THE ONE AN IMPLEMENTATION GETS
## BACKWARDS
## ---------------------------------------------------------------------
##
## Capture is lossless. Export is where a trust boundary is crossed, and it
## is the only place a value is ever rewritten. An implementation that
## redacted on the way in would satisfy every "the export contains no
## paths" check while permanently destroying the detail its owner is
## entitled to — and no query afterwards could tell it had happened.
##
## Structurally, that rule is kept by this module writing to exactly one
## file: the destination it created. There is no statement anywhere below
## that names ``sourcePath`` as the target of a write; the source is read
## by ``vacuum into``, which takes a READ transaction, and by
## ``canonicalDigest``. ``tests/unit/t_observation_store_export.nim``
## asserts it from the outside, by digesting the local store before and
## after and requiring the two to be equal — the same canonical form M15
## introduced, used here as an instrument for "nothing moved".
##
## Exporting onto the source itself is REFUSED rather than allowed to be
## the one redact-in-place path, because a caller who names one path twice
## has asked for exactly the thing the specification forbids.
##
## ---------------------------------------------------------------------
## HOW THE COPY IS MADE, AND WHY THE TRIGGER DANCE IS NOT OPTIONAL
## ---------------------------------------------------------------------
##
## ``vacuum into`` first, then rewrite the copy. That is ``backupTo``'s
## mechanism and it is here for ``backupTo``'s reason: it takes a read
## transaction, so a store being written by a live ``runquotad`` can be
## exported without stopping it.
##
## But ``executions`` carries the ``executions_immutable`` trigger (OS-3),
## which aborts every ``update``, including the ones a redaction pass has
## to make to ``command_stats_id``. So the pass drops the copy's triggers,
## rewrites, and RE-CREATES THEM FROM THE SQL THE COPY ITSELF CARRIES in
## ``sqlite_master`` — not from a second copy of the DDL kept here, which
## would drift from ``schema.nim`` the first time a migration touched it.
## All of it is one transaction, so a killed export leaves a destination
## that either does not exist or has its triggers.
##
## The exported store is therefore still an observation store: openable,
## still immutable, and still mergeable by the receiver. That is the point
## of exporting rather than dumping — the receiving side's operation is
## ``merge``, and §"Redaction" is a subsection of the merge chapter.
##
## ---------------------------------------------------------------------
## WHAT IS REDACTED, AND THE TWO SHAPES IT COMES IN
## ---------------------------------------------------------------------
##
## **Value-shaped: paths.** A path can appear in ANY text cell, including
## columns the specification says are not paths — ``workspace_id`` is
## documented as "a stable id for the workspace, not a path" and ``tool``
## as "free-form, client-declared", and a client that puts a path in either
## has disclosed the project structure just the same. So path redaction is
## applied to every text cell of every table discovered from
## ``sqlite_master``, not to a list of columns somebody expected paths in.
## A column-scoped path rule would be the campaign's recurring defect in
## its purest form: the check placed where it was convenient rather than
## where the dangerous thing happens.
##
## **Column-shaped: the things whose category is known from the schema.**
## Branch names, workspace ids, command stats ids, revisions and profile
## names are spine columns RunQuota owns and can classify. Each is replaced
## WHOLE, by a token, rather than scanned — a branch is disclosing as a
## name and not only as a path, and ``command_stats_id`` is bounded to 64
## bytes so a rewriting that grew it would be rejected by its own check
## constraint.
##
## Tokens are ``[redacted:<category>:<16 hex>]`` over the SHA-256 of the
## value. Deterministic on purpose: the same path in two exports maps to
## the same token, so a receiver can still group and count by it, and two
## exports of one store are canonically identical, which is what keeps an
## export mergeable without duplicating rows.
##
## **AND THE LIMIT OF THAT, STATED RATHER THAN IMPLIED.** A plain digest is
## correlatable, which is the feature, and it is therefore NOT a defence
## against an attacker who guesses candidate paths and hashes them. A
## policy needing that needs a keyed digest, and the key is the exporting
## organisation's business rather than the store's. Nothing here pretends
## otherwise.
##
## ---------------------------------------------------------------------
## EXTENSION TABLES, WHERE OS-5 CONSTRAINS THE ANSWER
## ---------------------------------------------------------------------
##
## RunQuota MUST NOT interpret extension columns, so it cannot classify
## one as "a branch name" and redact it as such. Two consequences, and both
## are asserted in the test rather than left as prose:
##
## * Under ``default``, an ``ext_`` table's text columns are PATH-SCANNED
##   like any other text and nothing else. A branch name sitting in a
##   product's own column survives. That is a real hole and it is visible:
##   the way to close it is ``strict``, or a future registration that lets
##   the declaring product mark its own columns, which is a schema change
##   this milestone does not make.
## * Under ``strict``, every non-key text value in an ``ext_`` table is
##   replaced wholesale. That is not interpretation; it is the refusal to
##   interpret, resolved conservatively at a trust boundary. Integers and
##   reals — the durations and byte counts an export exists to carry —
##   are untouched under every policy.
##
## ``carried_extension_rows.payload`` is redacted wholesale under
## ``default`` TOO, and the asymmetry is the point: a carried payload is a
## HEX rendering of somebody else's row, so the path scanner is blind
## inside it. Blindness at a trust boundary resolves to redaction, not to
## "no paths were found". Decoding the payload to scan it would be
## possible — RunQuota wrote that rendering — but it would hand the
## receiver bytes the exporter never inspected, which is the thing an
## export is supposed to stop.
##
## ---------------------------------------------------------------------
## WHAT IS NEVER REDACTED, AND WHY THAT IS A LIMIT RATHER THAN A CHOICE
## ---------------------------------------------------------------------
##
## **Key columns.** Every column that is part of a table's primary key, or
## either end of a foreign key anywhere in the database, is left alone. A
## rewritten key is a broken join, and an exported store whose executions
## no longer reach their run or their hardware profile is one OS-6 forbids
## the receiver from aggregating at all. The spine's ids are specified as
## opaque and machine-generated precisely so that this costs nothing —
## ``host_id`` "MUST NOT be a hostname" — and the four categories the
## specification names are none of them ids.
##
## It is still a hole if a client puts a path in a key, and the test says
## so out loud rather than leaving it to be discovered: the same path is
## asserted redacted in an ordinary column and NOT redacted in a key one.
## Closing it needs the tokens to be substituted on both sides of every
## foreign key inside one deferred-constraint transaction, which is a
## bigger change than this milestone's gate asks for.
##
## **Numbers.** Integers and reals are never touched under any policy.
## They are the durations, byte counts and exit statuses the export exists
## to carry; a policy that redacted them would produce an artifact with
## nothing in it, and the test's controls fail for exactly that reason.

import std/[options, os, strutils]

import ./canonical, ./extensions, ./schema, ./sha256, ./sqlite_cli

type
  RedactionPolicy* = enum
    ## ``CLI/stats.md``'s ``--redact=default|strict|none``.
    rpNone = "none"
    rpDefault = "default"
    rpStrict = "strict"

  RedactionCategory* = enum
    rcPath = "path"
      ## An absolute path, anywhere in any text cell.
    rcRelativePath = "relative-path"
      ## A slash-bearing token that is not rooted. ``strict`` only: it
      ## over-redacts by construction, which is what ``strict`` is for.
    rcBranch = "branch"
    rcWorkspace = "workspace"
    rcCommand = "command"
      ## ``executions.command_stats_id``: opaque to RunQuota, assigned by
      ## the client while constructing its action graph, and therefore the
      ## spine's carrier of command-line shape.
    rcRevision = "revision"
    rcProfile = "profile"
    rcExtension = "extension"
      ## A text value in a product-owned or carried row, replaced whole
      ## because RunQuota may not read it (OS-5).

  ExportOutcome* = enum
    xoExported = "exported"
    xoUnavailable = "unavailable"
    xoSourceUnreadable = "source-unreadable"
    xoDestinationExists = "destination-exists"
    xoDestinationIsSource = "destination-is-source"
    xoFailed = "failed"

  RedactionCounts* = array[RedactionCategory, int64]

  ExportReport* = object
    outcome*: ExportOutcome
    detail*: string
    policy*: RedactionPolicy
    categories*: set[RedactionCategory]
      ## Which categories the policy ACTIVATED, independently of whether
      ## any value matched. A reader needs the difference between "this
      ## policy does not redact branches" and "it does, and there were
      ## none".
    counts*: RedactionCounts
    cellsRewritten*: int64
    sourceDigest*: string
      ## The canonical digest of the source AS IT WAS EXPORTED. Recorded so
      ## a reader can pin the artifact to a source state; it discloses
      ## nothing, being a hash of a store it does not carry.

  ExportManifest* = object
    ## What ``export_manifest`` says, read back.
    present*: bool
      ## The table is there at all. ``false`` for a local store, which has
      ## never been exported and therefore has nothing to declare.
    ok*: bool
      ## The manifest is present AND readable. A present-but-unreadable
      ## manifest is a third state and must not read as either of the
      ## others.
    detail*: string
    format*: string
    policy*: RedactionPolicy
    policyText*: string
      ## Verbatim, so a policy name this build does not know is reported as
      ## itself rather than defaulting to one that happens to parse.
    categories*: set[RedactionCategory]
    counts*: RedactionCounts
    cellsRewritten*: int64
    sourceDigest*: string

const
  exportManifestTable* = "export_manifest"
    ## Written into the DESTINATION only, and deliberately not part of the
    ## migration ladder: a local store must not grow a table whose only
    ## purpose is to be empty. Its absence is therefore itself a fact — a
    ## store with no manifest has not been exported.

  exportManifestFormat* = "runquota-export-manifest/1"

  redactionTokenPrefix* = "[redacted:"

  pathRunChars* = {'a'..'z', 'A'..'Z', '0'..'9', '/', '\\', '.', '_', '-',
                   '~', '+'}
    ## The characters a path run is made of. Deliberately excludes the
    ## separators values are packed with elsewhere (``:``, ``=``, ``#``,
    ## ``|``, whitespace, quotes), so a run never swallows the structure
    ## around it. A Windows drive letter is picked up by looking BACK from
    ## a run that starts with a separator, since ``:`` is not in this set.

  extensionKeyColumns* = [keyHostColumn, keyExecutionColumn]
    ## Never redacted, under any policy: they are the join to the spine,
    ## and an extension row that cannot be joined is a row the receiver
    ## cannot use for anything at all.

  spineColumnCategories*: array[5, (string, string, RedactionCategory)] = [
    ("runs", "workspace_id", rcWorkspace),
    ("runs", "git_branch", rcBranch),
    ("runs", "git_commit", rcRevision),
    ("runs", "profile", rcProfile),
    ("executions", "command_stats_id", rcCommand)
  ]

proc activeCategories*(policy: RedactionPolicy): set[RedactionCategory] =
  ## The one place a policy is turned into a set of categories.
  case policy
  of rpNone:
    {}
  of rpDefault:
    {rcPath, rcBranch, rcWorkspace, rcCommand}
  of rpStrict:
    {rcPath, rcRelativePath, rcBranch, rcWorkspace, rcCommand, rcRevision,
     rcProfile, rcExtension}

proc parseRedactionPolicy*(text: string): Option[RedactionPolicy] =
  for policy in RedactionPolicy:
    if $policy == text:
      return some(policy)
  none(RedactionPolicy)

proc redactionToken*(category: RedactionCategory; value: string): string =
  ## Stable, category-qualified, and short enough that a redacted
  ## ``command_stats_id`` still fits the protocol's 64-byte bound.
  ##
  ## The category is part of the digested input, so the same string
  ## appearing as a branch and as a path does not produce one token that
  ## quietly asserts they are the same fact.
  redactionTokenPrefix & $category & ":" &
    sha256Hex($category & "\0" & value)[0 ..< 16] & "]"

proc redactPathsIn*(value: string; includeRelative: bool;
                    counts: var RedactionCounts): string =
  ## Rewrites every path-shaped run in ``value``.
  ##
  ## Runs, not whole values: a command fragment or a log line carries a
  ## path inside other text, and replacing the whole cell would destroy
  ## the part that is not disclosing anything.
  result = ""
  var i = 0
  while i < value.len:
    if value[i] notin pathRunChars:
      result.add(value[i])
      inc i
      continue
    var j = i
    while j < value.len and value[j] in pathRunChars:
      inc j
    let run = value[i ..< j]
    var start = i
    var category = rcPath
    var redact = false
    if run.len > 1 and (run[0] == '/' or run[0] == '\\'):
      redact = true
      # A Windows path arrives as `C:\...`; `:` is not a run character, so
      # the run starts at the separator and the drive is two characters
      # behind it. Take them into the token rather than leaving `C:` in
      # front of it.
      if i >= 2 and value[i - 1] == ':' and
          value[i - 2] in {'a'..'z', 'A'..'Z'} and
          (i == 2 or value[i - 3] notin pathRunChars):
        start = i - 2
        result.setLen(result.len - 2)
    elif run.len > 2 and run[0] == '~' and (run[1] == '/' or run[1] == '\\'):
      redact = true
    elif includeRelative and run.len > 1 and
        ('/' in run or '\\' in run):
      redact = true
      category = rcRelativePath
    if redact:
      result.add(redactionToken(category, value[start ..< j]))
      counts[category] += 1
    else:
      result.add(run)
    i = j

proc columnCategory*(table, column: string;
                     active: set[RedactionCategory]): Option[RedactionCategory] =
  ## The wholesale category for one column, if the policy activated it.
  for entry in spineColumnCategories:
    if entry[0] == table and entry[1] == column and entry[2] in active:
      return some(entry[2])
  if rcExtension in active and table.startsWith(extensionTablePrefix) and
      column notin extensionKeyColumns:
    return some(rcExtension)
  # The carried payload is opaque HEX. The path scanner cannot see into it
  # under ANY policy, so it is redacted from `default` upward rather than
  # certified clean by a scan that was structurally unable to find
  # anything. See the module header.
  if table == carriedExtensionTable and column == "payload" and
      active.len > 0:
    return some(rcExtension)
  none(RedactionCategory)

proc redactCell*(table, column, value: string;
                 active: set[RedactionCategory];
                 counts: var RedactionCounts): string =
  ## One text cell, rewritten. Returns the value unchanged when nothing
  ## applies, which is what lets the pass write only the cells it moved.
  let wholesale = columnCategory(table, column, active)
  if wholesale.isSome:
    counts[wholesale.get] += 1
    return redactionToken(wholesale.get, value)
  if rcPath notin active:
    return value
  redactPathsIn(value, rcRelativePath in active, counts)

proc textCellExpression(column: string): string =
  ## Only TEXT cells are candidates. Integers, reals, blobs and NULL are
  ## rendered as the null marker and skipped: rewriting a NULL would invent
  ## a value where the store deliberately records that nobody said, and
  ## rewriting a number would destroy the statistic the export exists to
  ## carry.
  let quoted = quoteIdentifier(column)
  "case when typeof(" & quoted & ") = 'text' then 'x' || hex(" & quoted &
    ") else '" & nullMarker & "' end"

proc keyReference*(table, column: string): string =
  table & canonicalFieldSeparator & column

proc linesOf(path, sql: string; detail: var string): seq[string] =
  let outcome = runSqlite(path, sql)
  if not outcome.ok:
    detail = outcome.error.strip()
    if detail.len == 0:
      detail = "sqlite3 exited " & $outcome.exitCode
    return @[]
  for line in outcome.output.splitLines():
    if line.len > 0:
      result.add(line)

proc manifestStatement(report: ExportReport): string =
  ## The manifest, as one ``create``/``insert`` batch.
  ##
  ## Key/value rather than a wide row, so a later category is a new key and
  ## not a migration of a table that only ever lives inside an artifact.
  ## ``policy.categories`` is written even when empty, because "no
  ## categories" is the honest description of ``none`` and its ABSENCE
  ## would be indistinguishable from a manifest that never recorded them.
  var categories: seq[string] = @[]
  for category in RedactionCategory:
    if category in report.categories:
      categories.add($category)
  var sql = "drop table if exists " & exportManifestTable & ";\n" &
    "create table " & exportManifestTable & " (\n" &
    "  key text primary key,\n" &
    "  value text not null\n);\n"
  proc put(key, value: string) =
    sql.add("insert into " & exportManifestTable & " (key, value) values (" &
      encodeText(key) & ", " & encodeText(value) & ");\n")
  put("format", exportManifestFormat)
  put("policy", $report.policy)
  put("policy.categories", categories.join(","))
  put("source_digest", report.sourceDigest)
  put("cells_rewritten", $report.cellsRewritten)
  for category in RedactionCategory:
    if category in report.categories:
      put("redacted." & $category, $report.counts[category])
  sql

proc protectedColumns*(path: string; detail: var string): seq[string] =
  ## Every ``<table>#<column>`` a rewrite must not touch: primary keys, and
  ## both ends of every foreign key in the database.
  ##
  ## DISCOVERED, never listed — the same rule ``canonical.nim`` follows and
  ## for the same reason. An extension table arrives with its own keys, a
  ## later migration may add one, and a hardcoded list would protect
  ## exactly the schema somebody wrote down and silently break the rest.
  ##
  ## The names are hex-encoded on the way out so the separator can never
  ## appear inside one.
  const queries = [
    "select hex(m.name) || '" & canonicalFieldSeparator & "' || hex(i.name) " &
      "from sqlite_master m, pragma_table_info(m.name) i where " &
      "m.type = 'table' and substr(m.name, 1, 7) <> 'sqlite_' and i.pk > 0;",
    "select hex(m.name) || '" & canonicalFieldSeparator &
      "' || hex(f.\"from\") from sqlite_master m, " &
      "pragma_foreign_key_list(m.name) f where m.type = 'table' and " &
      "substr(m.name, 1, 7) <> 'sqlite_';",
    "select hex(f.\"table\") || '" & canonicalFieldSeparator &
      "' || hex(f.\"to\") from sqlite_master m, " &
      "pragma_foreign_key_list(m.name) f where m.type = 'table' and " &
      "substr(m.name, 1, 7) <> 'sqlite_' and f.\"to\" is not null;"
  ]
  for query in queries:
    for line in linesOf(path, query, detail):
      let parts = line.split(canonicalFieldSeparator)
      if parts.len != 2:
        continue
      let entry = keyReference(parseHexStr(parts[0]), parseHexStr(parts[1]))
      if entry notin result:
        result.add(entry)
    if detail.len > 0:
      return @[]

proc redactCopy(path: string; active: set[RedactionCategory];
                report: var ExportReport): bool =
  ## The rewriting pass over the destination. Returns false with the reason
  ## in ``report.detail``.
  var detail = ""

  let protected = protectedColumns(path, detail)
  if detail.len > 0:
    report.detail = detail
    return false

  # THE TRIGGERS COME OFF AND GO BACK ON, from the copy's own SQL. The
  # separator is safe because both fields are hex.
  let triggers = linesOf(path,
    "select hex(name) || '" & canonicalFieldSeparator & "' || hex(sql) " &
    "from sqlite_master where type = 'trigger' and sql is not null;", detail)
  if detail.len > 0:
    report.detail = detail
    return false

  let tables = linesOf(path,
    "select name from sqlite_master where type = 'table' and " &
    "substr(name, 1, 7) <> 'sqlite_' order by name;", detail)
  if detail.len > 0:
    report.detail = detail
    return false

  var updates = ""
  for table in tables:
    let columns = linesOf(path, "select name from pragma_table_info(" &
      encodeText(table) & ") order by cid;", detail)
    if detail.len > 0:
      report.detail = detail
      return false
    var expressions: seq[string] = @[]
    for column in columns:
      expressions.add(textCellExpression(column))
    if expressions.len == 0:
      continue
    let rows = linesOf(path, "select rowid, " & expressions.join(", ") &
      " from " & quoteIdentifier(table) & ";", detail)
    if detail.len > 0:
      # A table without a rowid cannot be addressed for rewriting, and an
      # export that silently SKIPPED it would report a policy it had not
      # applied everywhere. Refuse instead.
      report.detail = "cannot read rows of " & table & ": " & detail
      return false
    for line in rows:
      let fields = line.split('|')
      if fields.len != columns.len + 1:
        report.detail = "unreadable row in " & table
        return false
      var assignments: seq[string] = @[]
      for index, column in columns:
        let field = fields[index + 1]
        if isNullField(field):
          continue
        if keyReference(table, column) in protected:
          continue
        let value = decodeText(field)
        let rewritten = redactCell(table, column, value, active, report.counts)
        if rewritten != value:
          report.cellsRewritten += 1
          assignments.add(quoteIdentifier(column) & " = " &
            encodeText(rewritten))
      if assignments.len > 0:
        updates.add("update " & quoteIdentifier(table) & " set " &
          assignments.join(", ") & " where rowid = " & fields[0] & ";\n")

  var sql = "begin immediate;\n"
  for line in triggers:
    let parts = line.split(canonicalFieldSeparator)
    if parts.len != 2:
      report.detail = "unreadable trigger definition"
      return false
    sql.add("drop trigger " & quoteIdentifier(parseHexStr(parts[0])) & ";\n")
  sql.add(updates)
  for line in triggers:
    let parts = line.split(canonicalFieldSeparator)
    sql.add(parseHexStr(parts[1]) & ";\n")
  sql.add("commit;\n")

  let outcome = runSqlite(path, sql)
  if not outcome.ok:
    report.detail = outcome.error.strip()
    if report.detail.len == 0:
      report.detail = "sqlite3 exited " & $outcome.exitCode
    return false
  true

proc exportObservationStore*(sourcePath, destinationPath: string;
                             policy: RedactionPolicy): ExportReport =
  ## Writes a redacted copy of ``sourcePath`` to ``destinationPath``.
  ## Never raises. The source is never written.
  result = ExportReport(outcome: xoFailed, detail: "", policy: policy,
    categories: activeCategories(policy), cellsRewritten: 0, sourceDigest: "")

  if not sqliteToolAvailable():
    result.outcome = xoUnavailable
    result.detail = "the '" & sqliteTool & "' tool is not on PATH"
    return
  if not fileExists(sourcePath):
    result.outcome = xoSourceUnreadable
    result.detail = "no such database: " & sourcePath
    return
  if absolutePath(sourcePath) == absolutePath(destinationPath):
    # BEFORE the "already exists" check, and the order is the point: a
    # caller naming one path twice has asked for redaction IN PLACE, which
    # is the one thing the specification forbids, and it must hear that
    # rather than the generic refusal it would otherwise collide with.
    result.outcome = xoDestinationIsSource
    result.detail = "refusing to export a store onto itself"
    return
  if fileExists(destinationPath):
    # Same refusal as ``backupTo``: an export that overwrote would make
    # "the artifact I sent" depend on what was there before.
    result.outcome = xoDestinationExists
    result.detail = "destination already exists: " & destinationPath
    return

  let integrity = runSqlite(sourcePath, "pragma quick_check;")
  if not integrity.ok or integrity.output.strip() != "ok":
    result.outcome = xoSourceUnreadable
    result.detail = "source is not a readable database"
    return

  let dump = canonicalDump(sourcePath)
  if not dump.ok:
    result.outcome = xoSourceUnreadable
    result.detail = dump.detail
    return
  result.sourceDigest = dump.digest

  if not runSqlite(sourcePath,
      "vacuum into " & encodeText(destinationPath) & ";").ok:
    result.outcome = xoFailed
    result.detail = "could not write " & destinationPath
    return

  if result.categories.len > 0:
    if not redactCopy(destinationPath, result.categories, result):
      result.outcome = xoFailed
      removeFile(destinationPath)
      return

  if not runSqlite(destinationPath, manifestStatement(result)).ok:
    result.outcome = xoFailed
    result.detail = "could not record the applied policy"
    removeFile(destinationPath)
    return

  # THE ARTIFACT IS VACUUMED LAST, AND THIS IS DEFENCE IN DEPTH RATHER
  # THAN A LOAD-BEARING STEP — MEASURED, NOT ASSUMED. The worry is real in
  # principle: an `update` can leave the cell it replaced in a page's free
  # space, so the bytes of a redacted path would still be in the file that
  # gets shipped even though no query returns them. `vacuum` rebuilds the
  # database into tightly packed pages, and the test reads the whole FILE
  # rather than trusting the query layer to speak for it.
  #
  # But removing this call is NOT detectable by that test: 0 of 10 runs.
  # The reason is a property of the `sqlite3` BINARY ON PATH rather than
  # of the export. `secure_delete` zeroes freed in-page content, so the
  # residue never arises — and it is a COMPILE-TIME default
  # (`SQLITE_SECURE_DELETE`), not something SQLite guarantees. The two
  # builds on the host this was measured on disagree about it: Apple's
  # `/usr/bin/sqlite3` reports 2 (FAST) and carries no such compile
  # option, nixpkgs' reports 1 (ON) and passes the flag explicitly. A
  # build that passes neither reports 0.
  #
  # SO THE CALL IS LOAD-BEARING AND THE TEST IS BLIND, WHICH IS NOT THE
  # SAME CONCLUSION AS THE CALL BEING UNNECESSARY. Measured both ways:
  # forcing `pragma secure_delete = 0` into the CLI preamble AND removing
  # this `vacuum` turns the export test red 5 of 5, with the fixture's
  # secrets recovered out of the artifact's free pages by the whole-file
  # scan; restoring the `vacuum` with `secure_delete` still 0 turns it
  # green again 5 of 5. `sqlite_cli.nim` resolves the tool through PATH,
  # so which build runs is a deployment fact this module cannot see.
  if not runSqlite(destinationPath, "vacuum;").ok:
    result.outcome = xoFailed
    result.detail = "could not compact " & destinationPath
    removeFile(destinationPath)
    return

  result.outcome = xoExported

proc readExportManifest*(path: string): ExportManifest =
  ## What an artifact says about itself. Never raises.
  ##
  ## Three outcomes, and a reader needs all three: no manifest at all (a
  ## store that was never exported), a manifest that cannot be read, and a
  ## manifest naming a policy. A single "policy" string with an empty value
  ## for the first two would let an unredacted store read as a redacted
  ## one.
  result = ExportManifest(present: false, ok: false, detail: "", format: "",
    policy: rpNone, policyText: "", categories: {}, cellsRewritten: 0,
    sourceDigest: "")
  if not sqliteToolAvailable():
    result.detail = "the '" & sqliteTool & "' tool is not on PATH"
    return
  if not fileExists(path):
    result.detail = "no such database: " & path
    return

  var detail = ""
  let present = linesOf(path, "select count(*) from sqlite_master where " &
    "type = 'table' and name = " & encodeText(exportManifestTable) & ";",
    detail)
  if detail.len > 0 or present.len != 1:
    result.detail = if detail.len > 0: detail else: "unreadable database"
    return
  if present[0].strip() != "1":
    result.detail = "this store carries no export manifest"
    return
  result.present = true

  let rows = linesOf(path, "select hex(key) || '" & canonicalFieldSeparator &
    "' || hex(value) from " & exportManifestTable & ";", detail)
  if detail.len > 0:
    result.detail = detail
    return

  var sawFormat = false
  var sawPolicy = false
  var sawCategories = false
  for line in rows:
    let parts = line.split(canonicalFieldSeparator)
    if parts.len != 2:
      result.detail = "unreadable manifest row"
      return
    let key = parseHexStr(parts[0])
    let value = parseHexStr(parts[1])
    case key
    of "format":
      result.format = value
      sawFormat = true
    of "policy":
      result.policyText = value
      sawPolicy = true
      let parsed = parseRedactionPolicy(value)
      if parsed.isSome:
        result.policy = parsed.get
      else:
        result.detail = "unknown redaction policy: " & value
        return
    of "policy.categories":
      sawCategories = true
      for name in value.split(','):
        if name.len == 0:
          continue
        var known = false
        for category in RedactionCategory:
          if $category == name:
            result.categories.incl(category)
            known = true
        if not known:
          result.detail = "unknown redaction category: " & name
          return
    of "source_digest":
      result.sourceDigest = value
    of "cells_rewritten":
      try:
        result.cellsRewritten = parseBiggestInt(value)
      except ValueError:
        result.detail = "unreadable cells_rewritten: " & value
        return
    else:
      if key.startsWith("redacted."):
        let name = key["redacted.".len .. ^1]
        for category in RedactionCategory:
          if $category == name:
            try:
              result.counts[category] = parseBiggestInt(value)
            except ValueError:
              result.detail = "unreadable count for " & name
              return

  if not sawFormat or not sawPolicy or not sawCategories:
    result.detail = "manifest is missing a required key"
    return
  if result.format != exportManifestFormat:
    result.detail = "unknown manifest format: " & result.format
    return
  result.ok = true
