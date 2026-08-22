## M12 gate, the inspection clause: NO RUNQUOTA CODE PATH READS AN
## EXTENSION COLUMN (OS-5).
##
## The behavioural half of the milestone — registration, independent
## migration, and the retention cascade — is
## ``t_observation_store_extensions``. This file asserts the thing no
## behaviour can: that the daemon has not grown an opinion about what a
## product's columns mean, and will fail loudly on the day it does.
##
## WHY AN INSPECTION TEST AT ALL. "RunQuota does not interpret extension
## columns" is trivially true today, because no extension exists yet. It
## stops being trivially true the moment ``ext_repro_action`` and the
## generic test layer land (M17, M19) and somebody notices that a cache
## outcome would make a lovely admission signal. What stands between that
## and the invariant is this file.
##
## WHAT IT IS PINNED TO, AND WHAT IT IS DELIBERATELY NOT PINNED TO. It is
## pinned to the NAMING RULE and the REGISTRY, which are the two things
## that make the boundary structural:
##
## * every extension table name is COMPOSED, from the ``ext_`` prefix and a
##   registered ``extension_id``, so a concrete extension table name in
##   ``libs/`` or ``apps/`` is a RunQuota code path that knows one
##   product's table by name;
## * every column name RunQuota writes into a statement against an
##   extension table is either the SPINE KEY it is joined by, or a name the
##   caller supplied.
##
## It is NOT pinned to a list of files. The source set is DISCOVERED by
## walking ``libs/`` and ``apps/``, so a violation in a module that does
## not exist yet is caught by a test written before it. A list would drift
## the first time somebody added a library, and would drift silently.
##
## AND IT CARRIES POSITIVE CONTROLS, because a scanner that matches nothing
## passes everywhere. Each of the three legs is run over source that really
## does contain what it is looking for — the synthetic extension's own
## fixture file for the table names and the payload columns, and
## ``store.nim`` for the column-name scanner, which is full of spine
## column names and is in the very file set the leg reports zero over.

import std/[algorithm, os, strutils, unittest]

import runquota_observation_store

const
  repoRoot = currentSourcePath().parentDir.parentDir.parentDir
  boundaryFile = repoRoot / "CLAUDE.md"
  extensionsSource =
    repoRoot / "libs" / "runquota_observation_store" / "src" /
    "runquota_observation_store" / "extensions.nim"
  schemaSource =
    repoRoot / "libs" / "runquota_observation_store" / "src" /
    "runquota_observation_store" / "schema.nim"
  storeSource =
    repoRoot / "libs" / "runquota_observation_store" / "src" /
    "runquota_observation_store" / "store.nim"
  fixtureSource = repoRoot / "tests" / "unit" /
    "t_observation_store_extensions.nim"

  identifierChars = {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_'}

  extensionPayloadColumns = [
    # Column names owned by an extension and by no spine table. Three of
      # them belong to the synthetic extension this milestone was built
      # against; the rest are the columns the specification names for the two
      # extensions that will really exist (§"Generic test-execution
      # extension", §"Reprobuild action extension"), listed here so that the
      # day one of them is READ by RunQuota is the day this test goes red,
      # and not the day somebody reviews the diff.
    "probe_label", "probe_count", "probe_weight",
    "test_id", "skip_reason", "error_message", "stdout_len", "stderr_len",
    "cache_outcome", "weak_fingerprint", "strong_fingerprint"]

  spineColumns = [
    # The control set for the column scanner: real column names, of the
      # same snake_case shape, in a spine table RunQuota owns outright.
    "peak_rss_bytes", "major_page_faults", "command_stats_id"]

proc runQuotaSources(): seq[string] =
  ## Every Nim source RunQuota ships, DISCOVERED rather than listed.
  ##
  ## Tests are excluded, and they have to be: a test of the extension
  ## mechanism must name a concrete extension table, which is exactly what
  ## this file forbids everywhere else. ``libs/*/tests`` is excluded on the
  ## same grounds as ``tests/``.
  for root in ["libs", "apps"]:
    for path in walkDirRec(repoRoot / root):
      if not path.endsWith(".nim"):
        continue
      if "/tests/" in path:
        continue
      result.add(path)
  result.sort()

proc concreteExtensionTables(text: string): seq[string] =
  ## Occurrences of the extension prefix followed by an identifier — that
  ## is, a CONCRETE extension table name rather than the prefix being
  ## composed with something.
  ##
  ## The character before the prefix has to be a non-identifier one, or
  ## every ``next_``, ``context_`` and ``plaintext_`` in the tree would be
  ## reported. That guard is asserted below rather than assumed.
  var index = 0
  while true:
    let hit = text.find(extensionTablePrefix, index)
    if hit < 0:
      break
    index = hit + extensionTablePrefix.len
    if hit > 0 and text[hit - 1] in identifierChars:
      continue
    if index >= text.len or text[index] notin identifierChars:
      continue
    var stop = index
    while stop < text.len and text[stop] in identifierChars:
      stop += 1
    let name = text[hit ..< stop]
    if name notin result:
      result.add(name)

proc tokensFound(text: string; tokens: openArray[string]): seq[string] =
  for token in tokens:
    if token in text:
      result.add(token)

suite "observation_store_extension_boundary":

  test "the boundary this file enforces is written down in the policy":
    # Pinned to the sentence in the policy file, so deleting the boundary
    # fails the test rather than quietly retiring it. This is the same
    # shape as the process-tree boundary in
    # `t_observation_store_ambient_attribution`, and for the same reason:
    # an invariant nobody wrote down is an invariant nobody can be held to.
    let boundary = readFile(boundaryFile)
    check "must not interpret extension" in boundary
    check "composed from the `ext_` prefix" in boundary
    check "arrived from the caller" in boundary

  test "no RunQuota source names a concrete extension table":
    let sources = runQuotaSources()
    # The walk found a tree, not a handful of files. A discovery that broke
    # would otherwise report zero violations over zero files.
    check sources.len >= 40
    check extensionsSource in sources
    check schemaSource in sources
    check storeSource in sources
    check fixtureSource notin sources

    var offenders: seq[string] = @[]
    for path in sources:
      for name in concreteExtensionTables(readFile(path)):
        offenders.add(path.relativePath(repoRoot) & ": " & name)
    if offenders.len > 0:
      echo "  m12 boundary: concrete extension tables named in RunQuota ",
        "source:"
      for offender in offenders:
        echo "    - ", offender
    check offenders.len == 0

    # NOT VACUOUS: the prefix IS present in the tree, in exactly the two
    # sanctioned spellings — composed in Nim, and stated as the registry's
    # own check constraint in SQL. Both are pinned, so the scanner reporting
    # nothing cannot mean the mechanism has gone away.
    let extensionsText = readFile(extensionsSource)
    let schemaText = readFile(schemaSource)
    check "extensionTablePrefix & extensionId" in extensionsText
    check "\"ext_\"" in extensionsText
    check "check (table_name = 'ext_' || extension_id)" in schemaText

    # THE POSITIVE CONTROL. The same scanner, over the fixture that really
    # does name concrete extension tables, must find them. Without this a
    # scanner that had stopped matching anything would agree with a daemon
    # that named every extension in the specification.
    let fixtureHits = concreteExtensionTables(readFile(fixtureSource))
    check "ext_m12_probe" in fixtureHits
    check "ext_m12_guard" in fixtureHits
    check fixtureHits.len >= 3

    # ... and the guard against false positives is asserted, not assumed:
    # an identifier that merely ENDS in the prefix is not a table name.
    check concreteExtensionTables("let next_step = context_id").len == 0
    check concreteExtensionTables("plaintext_body").len == 0
    check concreteExtensionTables("ext_probe").len == 1

  test "no RunQuota source names an extension-owned column":
    let sources = runQuotaSources()
    check sources.len >= 40

    var offenders: seq[string] = @[]
    var spineControlHits = 0
    for path in sources:
      let text = readFile(path)
      for token in tokensFound(text, extensionPayloadColumns):
        offenders.add(path.relativePath(repoRoot) & ": " & token)
      spineControlHits += tokensFound(text, spineColumns).len
    if offenders.len > 0:
      echo "  m12 boundary: extension-owned columns named in RunQuota source:"
      for offender in offenders:
        echo "    - ", offender
    check offenders.len == 0

    # THE POSITIVE CONTROL, AND IT IS RUN OVER THE SAME FILE SET the zero
    # above is reported over. Spine column names are the same shape as
    # extension ones and are all over `store.nim`; a scanner that could not
    # see them could not have seen an extension column either.
    check spineControlHits >= 6
    check tokensFound(readFile(storeSource), spineColumns).len ==
      spineColumns.len

    # And the payload scanner itself works: over the fixture that owns
    # those columns, it finds them.
    let fixtureHits = tokensFound(readFile(fixtureSource),
      extensionPayloadColumns)
    check "probe_label" in fixtureHits
    check "probe_count" in fixtureHits
    check "probe_weight" in fixtureHits

  test "the statements RunQuota emits carry no extension column of its own":
    # The leg that survives a violation written WITHOUT a literal table
    # name — `"select ... from " & row.tableName` would pass the scanners
    # above. What it could not do is put a column of its own choosing into
    # the statement, so the statements themselves are inspected.
    let table = extensionTableName("m12_probe")
    let row = ExtensionRow(hostId: "host-a", executionId: "exec-a",
      columns: @["probe_label", "probe_count"],
      values: @[extText("alpha"), extInt(3)])

    # THE CASCADE, which is the one statement RunQuota builds against an
    # extension table entirely on its own initiative. Its predicate lives
    # on the spine, and not one extension column appears in it.
    let cascade = extensionCascadeStatement(table, "host-a", 5000)
    check table in cascade
    check keyHostColumn in cascade
    check keyExecutionColumn in cascade
    check "executions" in cascade
    for column in extensionPayloadColumns:
      check column notin cascade

    # THE POSITIVE CONTROL FOR THE SAME CHECK: the insert, which is built
    # from the caller's row, DOES carry the caller's columns. Without this,
    # "no extension column appears" would be satisfied by a builder that
    # could not carry one at all.
    let insert = extensionInsertStatement(table, row)
    check "probe_label" in insert
    check "probe_count" in insert
    check keyHostColumn in insert
    check keyExecutionColumn in insert

    # And every payload column in that insert arrived in `row.columns`:
    # take them away and they are gone, which is what "RunQuota does not
    # name them" means operationally.
    let bare = extensionInsertStatement(table, ExtensionRow(
      hostId: "host-a", executionId: "exec-a", columns: @[], values: @[]))
    for column in extensionPayloadColumns:
      check column notin bare
    check keyHostColumn in bare
    check keyExecutionColumn in bare

  test "the cascade is driven by the registry, not by a list":
    # The other half of "not pinned to a list": an extension RunQuota has
    # never heard of is pruned anyway, because the registry is what says
    # which tables exist. The behavioural assertion lives in
    # `t_observation_store_extensions`; what is pinned here is that the
    # spine's own table list does NOT enumerate extension tables, so a new
    # extension cannot be forgotten by omission from it.
    for name in spineTableNames:
      check not name.startsWith(extensionTablePrefix)
    check "extension_registry" in spineTableNames
