## A canonical, layout-independent rendering of a whole observation store.
##
## WHY THIS MODULE EXISTS, AND WHY IT IS NOT AN ORNAMENT.
## ``reprobuild-specs/RunQuota-Observation-Store.md`` §"Merge And The
## Company-Wide Knowledge Base" requires that merging the same source
## twice, or two sources in either order, "MUST produce the same
## database". The M15 gate spells that as *byte-identical* databases.
##
## **A SQLite file cannot carry that claim, and pretending otherwise would
## be the weaker answer rather than the stronger one.** Every spine table
## is an ordinary rowid table, so SQLite assigns each inserted row an
## implicit rowid in *insertion* order; two merges that insert the same
## rows in different orders therefore place the same facts on different
## pages under different rowids. Page allocation and the freelist carry the
## same history. ``vacuum`` repacks the file but PRESERVES rowids, so it
## does not remove the difference either. The consequence is measurable
## rather than theoretical, and
## ``tests/unit/t_observation_store_merge.nim`` measures it: it builds two
## databases with identical content in different insert orders and asserts
## their bytes DIFFER while their canonical digests MATCH.
##
## So the identity is asserted over a canonical form instead, and this
## module is that form. What it must be, to be worth substituting:
##
## * **Total.** Every table is covered, and the set of tables is
##   DISCOVERED from ``sqlite_master`` rather than listed here — a table
##   added by a later migration, or an extension table that arrived with a
##   merge, is in the dump the day it exists. A hardcoded list would make
##   the digest blind exactly where the store is growing.
## * **Complete per row.** Every column of every row is rendered, in the
##   table's own column order, with the column list itself in the dump.
## * **Injective on observable content.** A cell is rendered as its storage
##   class and the hex of its bytes, so ``5`` the integer, ``'5'`` the
##   text, ``''`` the empty string and SQL ``NULL`` are four different
##   renderings. A digest that could not tell those apart would agree with
##   a merge that had lost the difference.
## * **Insensitive to nothing else.** Row order within a table is
##   normalised by sorting the rendered rows, and object order by sorting
##   the rendered schema objects — those are the two things that carry
##   insertion history and no observable meaning.
##
## The positive controls that hold this honest are in the merge test: one
## extra row, one changed cell, ``NULL`` against the empty string, an
## integer against its own text, a moved ``user_version``, a new schema
## object, and a table this module has never heard of all change the
## digest; a different physical layout does not.
##
## RunQuota reads extension columns HERE the way it reads them nowhere
## else, and it is still not interpreting them: the column names arrive
## from ``pragma_table_info`` on the database in front of it, never from
## this source file, and the values are hashed as opaque bytes. OS-5
## forbids RunQuota from having an opinion about what an extension column
## MEANS; carrying and comparing it without one is the whole job.

import std/[algorithm, os, strutils, tables]

import ./sha256, ./sqlite_cli

const
  canonicalFormat* = "runquota-canonical-dump/1"
    ## Stamped into the dump, so a digest computed by one version of this
    ## code is never silently compared against one computed by another.

  canonicalFieldSeparator* = "#"
    ## Safe by construction: every rendered field is either ``~`` or
    ## ``<storage-class>:<hex>``, and neither can contain this character.

  canonicalNullRendering* = "~"

type
  CanonicalDump* = object
    ok*: bool
    detail*: string
    userVersion*: int64
    tables*: seq[string]
      ## Every table the dump covered, sorted. Discovered, not listed.
    objects*: seq[string]
      ## Every schema object rendered, as ``<type>|<name>``.
    rows*: int64
    text*: string
    digest*: string

proc quoteIdentifier*(name: string): string =
  ## SQLite identifier quoting. Unlike the extension mechanism next door,
  ## this module cannot refuse an awkward name: it is describing a database
  ## that already exists, whatever somebody put in it.
  "\"" & name.replace("\"", "\"\"") & "\""

proc canonicalValueExpression*(column: string): string =
  ## SQL rendering one cell as ``~`` or ``<storage-class>:<hex>``.
  ##
  ## The storage class is part of the rendering on purpose. Without it a
  ## column holding the integer ``5`` and one holding the text ``'5'``
  ## would hash alike, and a merge that had coerced one into the other
  ## would pass the identity claim this module exists to carry.
  let quoted = quoteIdentifier(column)
  "case when " & quoted & " is null then '" & canonicalNullRendering &
    "' else typeof(" & quoted & ") || ':' || hex(cast(" & quoted &
    " as blob)) end"

proc canonicalRowExpression*(columns: openArray[string]): string =
  var parts: seq[string] = @[]
  for column in columns:
    parts.add(canonicalValueExpression(column))
  parts.join(" || '" & canonicalFieldSeparator & "' || ")

proc queryLines(path, sql: string; lines: var seq[string];
                detail: var string): bool =
  let outcome = runSqlite(path, sql)
  if not outcome.ok:
    detail = outcome.error.strip()
    if detail.len == 0:
      detail = "sqlite3 exited " & $outcome.exitCode
    return false
  lines = @[]
  for line in outcome.output.splitLines():
    if line.len > 0:
      lines.add(line)
  true

proc canonicalDump*(path: string): CanonicalDump =
  ## The whole database, rendered so that only observable content survives.
  ##
  ## Never raises. A database that cannot be read produces ``ok == false``
  ## and an empty digest, which is not the same value as any real digest —
  ## so an unreadable database can never compare equal to a readable one.
  result = CanonicalDump(ok: false, detail: "", userVersion: -1,
                         tables: @[], objects: @[], rows: 0, text: "",
                         digest: "")
  if not sqliteToolAvailable():
    result.detail = "the '" & sqliteTool & "' tool is not on PATH"
    return
  if not fileExists(path):
    result.detail = "no such database: " & path
    return

  # TWO `sqlite3` RUNS FOR THE WHOLE DATABASE, NOT TWO PER TABLE. Each run
  # is a process spawn, and a spawn is the whole cost of this proc: about
  # 30 ms on a quiet 32-CPU Windows host, and 160 ms on average -- six
  # seconds at worst -- on the same host with one other process holding
  # every CPU, against microseconds for the queries themselves. The
  # per-table form made a dump cost `2 * tables + 2` spawns, and
  # `t_observation_store_export`, which dumps a store 49 times, spent
  # 384 s of a 388 s run inside spawns under that load and was killed at
  # its 600 s bound during a full suite on a host busier still. The dump
  # TEXT is unchanged byte for byte, so every digest is too: only the
  # number of processes it takes to compute one moved.
  #
  # The first run reads everything the second needs to be written: the
  # user version, the schema objects and every table's columns, each kind
  # of line tagged so they cannot be confused. Names in the column lines
  # are hex, so no name can contain the separator. The second reads every
  # table's rows, each row prefixed by its table's index.
  var lines: seq[string] = @[]
  var detail = ""

  if not queryLines(path,
      "pragma user_version;\n" &
      "select 'object" & canonicalFieldSeparator & "' || type || '" &
        canonicalFieldSeparator & "' || name || '" &
        canonicalFieldSeparator & "' || case when sql is null then '" &
        canonicalNullRendering & "' else hex(sql) end from sqlite_master " &
        "where substr(name, 1, 7) <> 'sqlite_' order by type, name;\n" &
      "select 'column" & canonicalFieldSeparator & "' || hex(m.name) || '" &
        canonicalFieldSeparator & "' || hex(i.name) " &
        "from sqlite_master m, pragma_table_info(m.name) i " &
        "where m.type = 'table' and substr(m.name, 1, 7) <> 'sqlite_' " &
        "order by m.name, i.cid;",
      lines, detail):
    result.detail = detail
    return
  # THE SCHEMA, DISCOVERED. `substr` rather than `like`, because `_` is a
  # LIKE wildcard and `name like 'sqlite_%'` would also exclude a table
  # somebody called `sqliteXfoo`.
  const
    objectTag = "object" & canonicalFieldSeparator
    columnTag = "column" & canonicalFieldSeparator
  if lines.len == 0 or lines[0].startsWith(objectTag) or
      lines[0].startsWith(columnTag):
    result.detail = "unreadable user_version"
    return
  try:
    result.userVersion = parseBiggestInt(lines[0].strip())
  except ValueError:
    result.detail = "unreadable user_version: " & lines[0]
    return

  var objectLines: seq[string] = @[]
  var columnsOf = initTable[string, seq[string]]()
  for line in lines[1 .. ^1]:
    if line.startsWith(objectTag):
      objectLines.add(line[objectTag.len .. ^1])
    elif line.startsWith(columnTag):
      let parts = line[columnTag.len .. ^1].split(canonicalFieldSeparator)
      if parts.len != 2:
        result.detail = "unreadable column listing: " & line
        return
      try:
        columnsOf.mgetOrPut(parseHexStr(parts[0]), @[]).add(
          parseHexStr(parts[1]))
      except ValueError:
        result.detail = "unreadable column listing: " & line
        return
    else:
      result.detail = "unexpected schema line: " & line
      return
  objectLines.sort()

  var tableNames: seq[string] = @[]
  for line in objectLines:
    let parts = line.split(canonicalFieldSeparator)
    if parts.len < 2:
      continue
    result.objects.add(parts[0] & "|" & parts[1])
    if parts[0] == "table":
      tableNames.add(parts[1])
  tableNames.sort()
  result.tables = tableNames

  var body = canonicalFormat & "\n"
  body.add("user_version=" & $result.userVersion & "\n")
  for line in objectLines:
    body.add("object=" & line & "\n")

  var rowsSql = ""
  for index, table in tableNames:
    let columns = columnsOf.getOrDefault(table)
    if columns.len == 0:
      result.detail = "table " & table & " reports no columns"
      return
    rowsSql.add("select '" & $index & canonicalFieldSeparator & "' || " &
      canonicalRowExpression(columns) & " from " & quoteIdentifier(table) &
      ";\n")
  var rowsOf = newSeq[seq[string]](tableNames.len)
  if rowsSql.len > 0:
    if not queryLines(path, rowsSql, lines, detail):
      result.detail = detail
      return
    for line in lines:
      let at = line.find(canonicalFieldSeparator)
      var index = -1
      if at > 0:
        try: index = parseInt(line[0 ..< at])
        except ValueError: index = -1
      if index < 0 or index >= tableNames.len:
        result.detail = "unexpected row line: " & line
        return
      rowsOf[index].add(line[at + 1 .. ^1])

  for index, table in tableNames:
    body.add("table=" & table & "|" & columnsOf[table].join(",") & "\n")
    var rows = rowsOf[index]
    rows.sort()
    body.add("rowcount=" & table & "|" & $rows.len & "\n")
    result.rows += int64(rows.len)
    for row in rows:
      body.add("row=" & table & "|" & row & "\n")

  result.text = body
  result.digest = sha256Hex(body)
  result.ok = true

proc canonicalDigest*(path: string): string =
  ## The digest alone. Empty for a database that could not be read, which
  ## is deliberately not a value any readable database can produce.
  canonicalDump(path).digest
