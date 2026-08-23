## M13a gate, the negative control: ``runquotad`` IS THE ONLY SANCTIONED
## READER of the observation store, and client code that opens the database
## file directly fails this inspection gate.
##
## WHY AN INSPECTION GATE AND NOT A BEHAVIOURAL TEST. There is no runtime
## moment at which a client opening the file misbehaves. It works. It is
## faster than a round trip. It returns real rows. What it skips is
## everything the daemon applies on the way out — uid scoping from peer
## credentials, hardware qualification, the unknown-versus-zero
## distinction — and it does so silently, on a schema RunQuota owns and
## migrates. The only place that can be caught is the source.
##
## WHAT IT IS PINNED TO. Not a list of files: the source set is DISCOVERED
## by walking ``libs/`` and ``apps/``, so a violation in a module that does
## not exist yet is caught by a test written before it. It is pinned to two
## facts about each file — does it import the observation store, and does
## it name a reader entry point — and to the SANCTIONED SET those two facts
## are allowed to be true of.
##
## AND IT CARRIES BOTH CONTROLS, because a scanner that matches nothing
## passes everywhere and a scanner that matches everything passes nowhere:
##
## * a fixture that really does open the database from client code, which
##   MUST be flagged;
## * a fixture that does the same job over the socket, which MUST NOT be;
## * the shipped ``runquota_client`` source, which must be unflagged;
## * the shipped ``runquota_daemon`` source, which must be flagged — it is
##   the sanctioned reader, and a scanner that could not see even that one
##   is looking for the wrong thing.

import std/[algorithm, os, strutils, unittest]

const
  repoRoot = currentSourcePath().parentDir.parentDir.parentDir

  fixtureDir = repoRoot / "tests" / "fixtures" / "observation-store-readers"
  directReaderFixture = fixtureDir / "direct_reader_client.nim"
  socketReaderFixture = fixtureDir / "socket_reader_client.nim"

  storeLibraryRoot = "libs/runquota_observation_store"

  sanctionedReaders = [
    # `runquotad` and the daemon library it is built from. Nothing else.
      # The store library itself is excluded separately below: it IS the
      # store, and a rule saying the implementation may not touch its own
      # tables would be nonsense.
    "libs/runquota_daemon",
    "apps/runquotad",
    # THE LEARNED-ESTIMATE STORE, which is a DIFFERENT database with a
    # different owner and no spine tables in it. It reaches SQLite, so the
    # database-access leg of the scan would otherwise report it; it is
    # exempt because it is daemon-side and never linked by a client, and
    # THAT is asserted below rather than asserted here in a comment.
    "libs/runquota_persistence"]

  clientFacingRoots = [
    # What a consumer links. If the store were reachable from any of these
      # the boundary would be gone whatever the daemon did.
      #
      # THE LIST'S COMPLETENESS IS PART OF THE RULE, not a detail of it.
      # The sweep below exempts `runquota_persistence`, so a client-side
      # module missing from this list could reach SQLite through the one
      # library already waved through and nothing would notice. The
      # process helpers are here for exactly that reason: the repository's
      # own boundary document names them client-side, and they are as
      # linked by a consumer as the client library is.
    "libs/runquota_client",
    "libs/runquota_cli_support",
    "libs/runquota_protocol",
    "libs/runquota_exec",
    "libs/runquota_process",
    "apps/runquota/"]

  storeModuleTokens = [
    # Naming the library is the import, however it is spelled.
    "runquota_observation_store"]

  readerTokens = [
    # The entry points that READ. A file that names one of these is
      # answering a question about recorded rows, which is the daemon's job.
    "openObservationStore",
    "readExecutions",
    "readRuns",
    "readHostProfiles",
    "readAmbientSamples",
    "readExtensionRegistry",
    "runQuery",
    "estimateFor",
    "queryExecutions",
    "queryRanking",
    # And the database itself, named by file or by tool. A client that
    # reached SQLite directly would not need any symbol above.
    "observations.sqlite3",
    "runSqlite",
    "sqlite3"]

proc runQuotaSources(): seq[string] =
  ## Every Nim source RunQuota ships, DISCOVERED rather than listed. Tests
  ## are excluded: a test of the read path must construct fixtures through
  ## the store library, which is exactly what this file forbids everywhere
  ## else.
  for root in ["libs", "apps"]:
    for path in walkDirRec(repoRoot / root):
      if not path.endsWith(".nim"):
        continue
      if "/tests/" in path:
        continue
      result.add(path)
  result.sort()

proc relativeToRepo(path: string): string =
  if path.startsWith(repoRoot & "/"): path[repoRoot.len + 1 .. ^1] else: path

proc codeOnly(text: string): string =
  ## The source with comments removed.
  ##
  ## SCANNING PROSE WOULD MAKE THIS GATE USELESS IN BOTH DIRECTIONS. Files
  ## in this tree explain themselves at length and routinely name the
  ## module they are NOT allowed to link — this very sentence would trip a
  ## scanner that read comments. A gate that fires on documentation gets
  ## silenced; a silenced gate guards nothing.
  ##
  ## The cut is STRING-AWARE. A ``#`` inside a literal is not a comment,
  ## and cutting there would silently drop the rest of the line — which is
  ## a FALSE NEGATIVE, the one direction a gate must not fail in.
  var lines: seq[string] = @[]
  for line in text.splitLines():
    var inString = false
    var escaped = false
    var cut = line.len
    for index, character in line:
      if escaped:
        escaped = false
      elif character == '\\' and inString:
        escaped = true
      elif character == '"':
        inString = not inString
      elif character == '#' and not inString:
        cut = index
        break
    lines.add(line[0 ..< cut])
  lines.join("\n")

proc readsTheStore(source: string): seq[string] =
  ## The tokens that make a file a reader of the observation store. Both
  ## halves are reported so a failure names what it saw rather than merely
  ## that it saw something.
  let text = codeOnly(source)
  var namesStore = false
  for token in storeModuleTokens:
    if token in text:
      namesStore = true
      break
  for token in readerTokens:
    if token notin text:
      continue
    # `sqlite3` and `runSqlite` are reads of a database with no help from
    # the store library at all, so they count on their own. Everything else
    # is a store entry point and only means anything in a file that has the
    # library in scope.
    if token in ["sqlite3", "runSqlite", "observations.sqlite3"] or namesStore:
      if token notin result:
        result.add(token)

proc isSanctioned(relativePath: string): bool =
  if relativePath.startsWith(storeLibraryRoot):
    return true
  for prefix in sanctionedReaders:
    if relativePath.startsWith(prefix):
      return true
  false

suite "observation_store_reader_boundary":

  test "the boundary is written down where a reader of this repo will see it":
    # A GATE NOBODY CAN FIND THE RULE FOR GETS DELETED as an obstacle. The
    # rule lives in the repository's own boundary document, and the wording
    # is pinned so that removing it fails here rather than quietly.
    let boundary = readFile(repoRoot / "AGENTS.md")
    check "only sanctioned reader of the observation store" in boundary
    check "No client\n  may open the database file directly" in boundary
    check "must not clamp it, second-guess it, or validate it against its own" in
      boundary

  test "the scanner flags client code that opens the database directly":
    # THE NEGATIVE CONTROL. This is the shape the gate exists to refuse,
    # written the way somebody would really write it, and it must be
    # caught.
    check fileExists(directReaderFixture)
    let hits = readsTheStore(readFile(directReaderFixture))
    check hits.len > 0
    check "openObservationStore" in hits
    check "readExecutions" in hits

  test "the scanner does not flag a client that asks over the socket":
    # THE POSITIVE CONTROL, in the other direction. Without it a scanner
    # that rejected every file would pass the test above and forbid the
    # only correct way to do the job.
    check fileExists(socketReaderFixture)
    check readsTheStore(readFile(socketReaderFixture)).len == 0

  test "the scanner can see the reader it is supposed to permit":
    # A SCANNER THAT MATCHES NOTHING PASSES EVERYWHERE. If it cannot find
    # the daemon -- which really does open the store, read profiles, and
    # answer queries -- then "no client reads the store" is a statement
    # about the scanner and not about the tree.
    let daemonSource =
      repoRoot / "libs" / "runquota_daemon" / "src" / "runquota_daemon.nim"
    check fileExists(daemonSource)
    let hits = readsTheStore(readFile(daemonSource))
    check hits.len > 0
    check "openObservationStore" in hits

  test "no shipped client library or app reads the observation store":
    # THE GATE ITSELF, over the discovered tree.
    let sources = runQuotaSources()
    # The source set is real, and it includes the files this rule is
    # actually about.
    check sources.len > 20
    var sawClient = false
    var sawCli = false
    for path in sources:
      let relative = relativeToRepo(path)
      if relative.startsWith("libs/runquota_client/"):
        sawClient = true
      if relative.startsWith("apps/runquota/"):
        sawCli = true
    check sawClient
    check sawCli

    var offenders: seq[string] = @[]
    for path in sources:
      let relative = relativeToRepo(path)
      if isSanctioned(relative):
        continue
      let hits = readsTheStore(readFile(path))
      if hits.len > 0:
        offenders.add(relative & " -> " & hits.join(", "))
    if offenders.len > 0:
      echo "unsanctioned observation-store readers:"
      for offender in offenders:
        echo "  " & offender
    check offenders.len == 0

  test "no client-facing module links either database library":
    # THE EXEMPTION ABOVE IS ONLY SOUND IF IT IS DAEMON-SIDE. A scan that
    # waved `runquota_persistence` through without checking that would be
    # a hole in the boundary shaped exactly like the one the boundary
    # exists to close: a client that reached SQLite would only have to do
    # it through the library already permitted to.
    for path in runQuotaSources():
      let relative = relativeToRepo(path)
      var clientFacing = false
      for root in clientFacingRoots:
        if relative.startsWith(root):
          clientFacing = true
          break
      if not clientFacing:
        continue
      let text = codeOnly(readFile(path))
      check "runquota_persistence" notin text
      check "runquota_observation_store" notin text

  test "the client library reaches the store only over the socket":
    # Stated separately from the sweep above, because this is the file the
    # rule is FOR: `runquota_client` is what every consumer links, and it
    # is the one place where "just open the file" would be both easiest and
    # most damaging.
    let clientSource =
      repoRoot / "libs" / "runquota_client" / "src" / "runquota_client.nim"
    check readsTheStore(readFile(clientSource)).len == 0
    # And it really does have a way to ask, so "does not read the store" is
    # not satisfied by a library that cannot answer the question at all.
    let clientCode = codeOnly(readFile(clientSource))
    check "queryStats" in clientCode
    check "rqStatsQuery" in clientCode
