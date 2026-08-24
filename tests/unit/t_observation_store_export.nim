## M16 gate: an export records the policy that was applied to it,
## command-line fragments / paths / branch names are redacted PER POLICY,
## and redaction happens at EXPORT and not at capture — a local store
## retains full detail.
##
## ---------------------------------------------------------------------
## THE THREE CLAUSES ARE ALL ABSENCES, AND AN ABSENCE IS THE EASIEST THING
## TO SATISFY BY ACCIDENT
## ---------------------------------------------------------------------
##
## "The export does not contain ``/Users/zahary``" is satisfied by an
## export that is EMPTY, TRUNCATED, or that never ran. Every absence
## asserted below is therefore paired with a POSITIVE CONTROL proving the
## artifact carries what it is for: per-table row counts equal to the
## source's, the same duration total, the same hardware dimension, the same
## untouched dimensions (``tool_version``, ``termination``,
## ``capture_completeness``, ``cpu_model``), and the export still being an
## openable, still-immutable, still-mergeable observation store. Those same
## controls are what a "redact everything" policy fails, without which
## "redact all" would satisfy every clause in the gate.
##
## "Redaction is at export, not at capture" is an absence about the OTHER
## database, and it passes trivially in any run that simply did not look at
## the local store. It is asserted by digesting the local store with M15's
## canonical form BEFORE and AFTER an export and requiring equality, and
## then — because two unreadable stores also compare equal — by reading the
## originals back out of it through the library's own read path.
##
## ---------------------------------------------------------------------
## THE FIXTURE IS BUILT TO HAVE SOMETHING TO LOSE
## ---------------------------------------------------------------------
##
## A policy that redacts nothing passes against a store with nothing in it
## to redact, so the local store below carries a real absolute path, a real
## relative path, a Windows path with a drive letter, a branch name, a
## workspace id, a command stats id naming a source file, a product-owned
## extension row with a path and a branch in it, and a CARRIED extension
## row whose payload is the hex rendering of another machine's values. Each
## secret is a distinct string, so an assertion that one is gone cannot be
## satisfied by another one being gone.
##
## The whole exported FILE is scanned for each secret, in both its literal
## and its hex-encoded form, rather than only the columns a reader would
## think to check — a redaction that missed a table is invisible to a query
## and visible to that scan. What that scan does NOT demonstrate, measured
## rather than assumed, is residue in freed pages: removing the export's
## final ``vacuum`` leaves this file green in 10 of 10 runs, because the
## ``sqlite3`` on this host zeroes freed in-page content. That is a
## property of the BINARY and not of SQLite — ``secure_delete`` is a
## compile-time default and a build that sets neither flag reports ``0``,
## where the same removal turns this file RED 5 of 5. So the ``vacuum``
## is load-bearing on some hosts and merely unasserted on this one;
## ``redaction.nim`` carries both measurements.
##
## ONE STRING IS DELIBERATELY NOT REDACTED, and it is asserted rather than
## omitted: ``secretIdPath`` sits in ``runs.run_id`` and, verbatim, in
## ``runs.tool`` of the same row. The first is a primary key that
## ``executions`` joins through and no policy rewrites it; the second is
## rewritten by ``default``. That pair is the limit stated as a
## measurement, and removing the key protection reddens it.
##
## NO MOCKS. Real SQLite files, real exports, and the local store is built
## by the same library the daemon writes with; the carried rows arrive
## through the real ``merge``.

import std/[options, os, strutils, times, unittest]

import runquota_observation_store

proc scratchDir(name: string): string =
  result = getTempDir() / ("rq-m16x-" & name & "-" &
    $getCurrentProcessId() & "-" & $epochTime())
  removeDir(result)
  createDir(result)

# ---------------------------------------------------------------------------
# The secrets. Distinct on purpose.
# ---------------------------------------------------------------------------

const
  secretAbsolutePath = "/Users/zahary/work/acme-payments/build/bin/repro"
  secretRelativePath = "vendor/acme-invoicing/bin/linker"
  secretWindowsPath = "C:\\Users\\zahary\\acme-billing\\build.log"
  secretHomePath = "~/src/acme-ledger/main.nim"
  secretWorkspace = "ws-acme-payments-prod"
  secretBranch = "feature/acme-launch"
  secretCommit = "9f1c2d3e4b5a69780f1e2d3c4b5a6978c0ffee11"
  secretProfile = "release-acme-payments"
  secretCommand = "nim-c:acme_settlement_engine"
  secretExtPath = "/Users/zahary/work/acme-payments/src/settlement.nim"
  secretExtBranch = "feature/acme-invoicing-v2"
  secretCarriedPath = "/Users/zahary/work/acme-vendor/third_party/x.c"

  # NOT in `everySecret`, because it is the one path an export does NOT
  # remove. It is placed in a KEY column and, verbatim, in an ordinary one,
  # so the limit is a measured pair rather than a sentence in a comment.
  secretIdPath = "/Users/zahary/work/acme-keys/run-3"

  everySecret = [secretAbsolutePath, secretRelativePath, secretWindowsPath,
                 secretHomePath, secretWorkspace, secretBranch, secretCommit,
                 secretProfile, secretCommand, secretExtPath, secretExtBranch,
                 secretCarriedPath]

  localHost = "host-m16"
  localProfile = "profile-m16"
  vendorHost = "host-m16-vendor"
  vendorProfile = "profile-m16-vendor"

  knownExtension = "m16x_action"
  vendorExtension = "m16x_vendor"
  fixtureOwner = "runquota-m16"

  knownDdl = """
create table ext_m16x_action (
  host_id text not null,
  execution_id text not null,
  action_label text,
  branch_label text,
  log_path text,
  wall_millis integer,
  weight real,
  primary key (host_id, execution_id),
  foreign key (host_id, execution_id)
    references executions(host_id, execution_id)
);
"""

  vendorDdl = """
create table ext_m16x_vendor (
  host_id text not null,
  execution_id text not null,
  vendor_path text not null,
  primary key (host_id, execution_id),
  foreign key (host_id, execution_id)
    references executions(host_id, execution_id)
);
"""

proc knownDeclaration(): ExtensionDeclaration =
  ExtensionDeclaration(extensionId: knownExtension, owner: fixtureOwner,
    schemaVersion: 1, migrations: @[knownDdl])

proc vendorDeclaration(): ExtensionDeclaration =
  ExtensionDeclaration(extensionId: vendorExtension, owner: fixtureOwner,
    schemaVersion: 1, migrations: @[vendorDdl])

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

proc profileRow(hostId, profileId: string): HostProfileRow =
  HostProfileRow(hostId: hostId, profileId: profileId,
    profileHash: "sha256:" & profileId, validFromUnixMillis: 1_000,
    validToUnixMillis: none(int64), cpuModel: "Apple M2 Max",
    physicalCores: 12, logicalCores: 12, ramBytes: 1 shl 36, swapBytes: 0,
    diskClass: dcNvme, fsType: "apfs", arch: "arm64", os: "macos",
    osVersion: "15.3", kernelVersion: "24.3.0", virtualization: "none",
    cpuShareGroup: "default")

proc execution(hostId, profileId, runId, id, commandStatsId: string;
               startedAt, duration: int64): ExecutionRow =
  ExecutionRow(executionId: id, hostId: hostId,
    hostProfileId: some(profileId), runId: runId,
    commandStatsId: commandStatsId, startedAtUnixMillis: startedAt,
    finishedAtUnixMillis: startedAt + duration, durationMillis: duration,
    exitStatus: 0, termination: tExited, attempt: 1, peakRssBytes: 4096,
    maxProcesses: 1, majorPageFaults: 3, captureCompleteness: ccComplete)

proc vendorSource(path: string): ObservationStore =
  ## Another machine's store, holding an extension this receiver has never
  ## heard of. Merging it is what puts a CARRIED row — an opaque hex
  ## payload with somebody else's path inside it — into the local store.
  result = openObservationStore(path)
  doAssert result.captureEnabled, result.report
  doAssert result.insertHost(HostRow(hostId: vendorHost,
    createdAtUnixMillis: 500, lastBootId: "boot-vendor"))
  doAssert result.insertHostProfile(profileRow(vendorHost, vendorProfile))
  doAssert result.insertRun(RunRow(runId: "run-vendor", hostId: vendorHost,
    tool: "vendor-build", toolVersion: "1.0", invocationKind: "build",
    startedAtUnixMillis: 500, captureCompleteness: ccComplete))
  doAssert result.declareExtension(vendorDeclaration()) == eoCreated
  doAssert result.insertExecution(execution(vendorHost, vendorProfile,
    "run-vendor", "vendor-exec-1", "vendor-cmd", 500, 7))
  doAssert result.insertExtensionRow(vendorDeclaration(), ExtensionRow(
    hostId: vendorHost, executionId: "vendor-exec-1",
    columns: @["vendor_path"],
    values: @[extText(secretCarriedPath)])) == ewWritten

proc buildLocalStore(dir, path: string): ObservationStore =
  ## The store a developer's machine accumulates: full detail, nothing
  ## redacted, exactly as OS-3 and the "redact at export" rule require.
  result = openObservationStore(path)
  doAssert result.captureEnabled, result.report
  doAssert result.insertHost(HostRow(hostId: localHost,
    createdAtUnixMillis: 1_000, lastBootId: "boot-local"))
  doAssert result.insertHostProfile(profileRow(localHost, localProfile))
  doAssert result.declareExtension(knownDeclaration()) == eoCreated

  # RUN ONE carries every column-classified secret at once.
  doAssert result.insertRun(RunRow(runId: "run-1", hostId: localHost,
    tool: secretAbsolutePath, toolVersion: "2.14.0", invocationKind: "build",
    startedAtUnixMillis: 1_000, finishedAtUnixMillis: some(9_000'i64),
    exitStatus: some(0'i64), workspaceId: some(secretWorkspace),
    profile: some(secretProfile), gitCommit: some(secretCommit),
    gitBranch: some(secretBranch), captureCompleteness: ccComplete))
  # RUN TWO's `tool` is a RELATIVE path, which `default` leaves alone and
  # `strict` does not. It is the only difference between the two policies
  # that is value-shaped rather than column-shaped.
  doAssert result.insertRun(RunRow(runId: "run-2", hostId: localHost,
    tool: secretRelativePath, toolVersion: "2.14.0",
    invocationKind: "test", startedAtUnixMillis: 2_000,
    captureCompleteness: ccComplete))

  # RUN THREE puts the SAME string in a key column and in an ordinary one.
  # `run_id` is part of the primary key and is referenced by `executions`,
  # so no policy rewrites it; `tool` beside it is rewritten by `default`.
  doAssert result.insertRun(RunRow(runId: secretIdPath, hostId: localHost,
    tool: secretIdPath, toolVersion: "2.14.0", invocationKind: "check",
    startedAtUnixMillis: 3_000, captureCompleteness: ccComplete))

  for i in 1 .. 3:
    doAssert result.insertExecution(execution(localHost, localProfile,
      "run-1", "exec-" & $i, secretCommand, 1_000 + int64(i) * 10,
      int64(i) * 100))
  doAssert result.insertExecution(execution(localHost, localProfile, "run-2",
    "exec-4", "cmd-plain", 2_000, 40))

  # The product's own extension rows: a path, a branch name, a Windows path
  # with a drive letter, and the two numbers an export exists to carry.
  for i in 1 .. 2:
    doAssert result.insertExtensionRow(knownDeclaration(), ExtensionRow(
      hostId: localHost, executionId: "exec-" & $i,
      columns: @["action_label", "branch_label", "log_path", "wall_millis",
                 "weight"],
      values: @[extText(secretExtPath), extText(secretExtBranch),
                extText(secretWindowsPath), extInt(int64(i) * 1_000),
                extReal(0.25 * float64(i))])) == ewWritten
  # And one row whose label is a HOME-relative path, the third rooted shape.
  doAssert result.insertExtensionRow(knownDeclaration(), ExtensionRow(
    hostId: localHost, executionId: "exec-3",
    columns: @["action_label", "wall_millis"],
    values: @[extText(secretHomePath), extInt(7)])) == ewWritten

  doAssert result.insertAmbientSample(AmbientSampleRow(hostId: localHost,
    sampledAtUnixMillis: 1_500, cpuBusyPct: 41.5,
    memAvailableBytes: 1 shl 33, swapInRate: 0.0, ioQueueDepth: 1.5,
    loadAvg1m: 3.25, selfCpuPct: 12.5, selfRssBytes: 1 shl 20,
    foreignCpuPct: 29.0, foreignRssBytes: 1 shl 21))

  let vendor = dir / "vendor.sqlite"
  discard vendorSource(vendor)
  doAssert result.mergeObservationStore(vendor).outcome == moMerged

proc plainStore(path: string): ObservationStore =
  ## A store with NOTHING to redact in the column-shaped categories: no
  ## branch, no workspace id, no path anywhere. It exists so "the policy
  ## activated this category and found nothing" can be told apart from "the
  ## policy does not activate this category".
  result = openObservationStore(path)
  doAssert result.captureEnabled, result.report
  doAssert result.insertHost(HostRow(hostId: localHost,
    createdAtUnixMillis: 1_000, lastBootId: "boot-plain"))
  doAssert result.insertHostProfile(profileRow(localHost, localProfile))
  doAssert result.insertRun(RunRow(runId: "run-1", hostId: localHost,
    tool: "repro", toolVersion: "2.14.0", invocationKind: "build",
    startedAtUnixMillis: 1_000, captureCompleteness: ccComplete))
  doAssert result.insertExecution(execution(localHost, localProfile, "run-1",
    "exec-1", "cmd-plain", 1_000, 10))

# ---------------------------------------------------------------------------
# Reading helpers
# ---------------------------------------------------------------------------

proc scalar(path, sql: string): string =
  let outcome = runSqlite(path, sql)
  doAssert outcome.ok, outcome.error
  outcome.output.strip()

proc rowCounts(path: string): seq[string] =
  ## ``<table>=<rows>`` for every table, DISCOVERED rather than listed, so a
  ## table an export dropped is caught even though nothing here knows its
  ## name. The manifest is the one table an artifact is supposed to have
  ## that its source does not, so it is left out and asserted separately.
  let dump = canonicalDump(path)
  doAssert dump.ok, dump.detail
  for table in dump.tables:
    if table == exportManifestTable:
      continue
    result.add(table & "=" & scalar(path, "select count(*) from \"" &
      table & "\";"))

proc fileHolds(path, secret: string): bool =
  ## Does the artifact contain this secret ANYWHERE — as its own bytes, or
  ## as the uppercase hex a carried payload renders it in?
  let blob = readFile(path)
  secret in blob or secret.toHex() in blob

proc dumpWithout(path, table: string): string =
  ## The canonical dump with one table's lines removed, so two stores that
  ## differ only by the export manifest can still be compared as wholes.
  let dump = canonicalDump(path)
  doAssert dump.ok, dump.detail
  var kept: seq[string] = @[]
  for line in dump.text.splitLines():
    if ("|" & table & "|") in line or ("=" & table & "|") in line or
        (canonicalFieldSeparator & table & canonicalFieldSeparator) in line:
      continue
    kept.add(line)
  kept.join("\n")

proc exportOf(source, destination: string;
              policy: RedactionPolicy): ExportReport =
  result = exportObservationStore(source, destination, policy)
  doAssert result.outcome == xoExported, result.detail

suite "observation_store_export":

  # -------------------------------------------------------------------
  test "path shapes are recognised where they occur, and only there":
    # The scanner is the value-shaped half of the policy, so it is pinned
    # directly as well as end to end. Each arm is one shape; the last three
    # are the NEGATIVE arms, without which "redact anything containing a
    # slash" would pass every positive one.
    var counts: RedactionCounts

    let absolute = redactPathsIn("built " & secretAbsolutePath & " ok",
      includeRelative = false, counts)
    check secretAbsolutePath notin absolute
    check absolute.startsWith("built ")
    check absolute.endsWith(" ok")
    check redactionTokenPrefix & "path:" in absolute
    check counts[rcPath] == 1

    # A DRIVE LETTER IS PART OF THE PATH, and `:` is not a path character,
    # so a scanner that only looked forward would leave `C:` behind.
    counts = default(RedactionCounts)
    let windows = redactPathsIn(secretWindowsPath, false, counts)
    check "C:" notin windows
    check "zahary" notin windows
    check counts[rcPath] == 1

    counts = default(RedactionCounts)
    let home = redactPathsIn("nim c " & secretHomePath, false, counts)
    check "acme-ledger" notin home
    check counts[rcPath] == 1

    # RELATIVE PATHS ARE `strict` ONLY, and the two directions are asserted
    # against the same input.
    counts = default(RedactionCounts)
    check redactPathsIn(secretRelativePath, false, counts) ==
      secretRelativePath
    check counts[rcPath] == 0
    check counts[rcRelativePath] == 0
    counts = default(RedactionCounts)
    let relative = redactPathsIn(secretRelativePath, true, counts)
    check relative != secretRelativePath
    check counts[rcRelativePath] == 1
    check counts[rcPath] == 0

    # THE NEGATIVE ARMS. Ordinary values, and a bare separator, survive
    # both modes untouched.
    counts = default(RedactionCounts)
    for value in ["exited", "complete", "2.14.0", "Apple M2 Max", "/", "",
                  "sha256:abc"]:
      check redactPathsIn(value, false, counts) == value
      check redactPathsIn(value, true, counts) == value
    check counts[rcPath] == 0
    check counts[rcRelativePath] == 0

    # SAME VALUE, SAME TOKEN; different category, different token. The
    # first is what lets a receiver still group by a path it cannot read;
    # the second stops a token from asserting that a branch and a path were
    # the same string.
    check redactionToken(rcPath, secretAbsolutePath) ==
      redactionToken(rcPath, secretAbsolutePath)
    check redactionToken(rcPath, secretAbsolutePath) !=
      redactionToken(rcBranch, secretAbsolutePath)
    check redactionToken(rcPath, secretAbsolutePath) !=
      redactionToken(rcPath, secretExtPath)

  # -------------------------------------------------------------------
  test "the applied policy is recorded, and a store that never was exported says so":
    let dir = scratchDir("manifest")
    defer: removeDir(dir)
    let local = dir / "local.sqlite"
    discard buildLocalStore(dir, local)

    # A LOCAL STORE HAS NO MANIFEST, and that is a distinct state from a
    # manifest that says nothing. Without this arm, a reader returning an
    # empty policy for an unredacted store would read as `none`.
    let unexported = readExportManifest(local)
    check not unexported.present
    check not unexported.ok
    check "no export manifest" in unexported.detail

    var manifests: array[RedactionPolicy, ExportManifest]
    for policy in RedactionPolicy:
      let artifact = dir / ("export-" & $policy & ".sqlite")
      let report = exportOf(local, artifact, policy)
      check report.policy == policy
      check report.categories == activeCategories(policy)
      check report.sourceDigest == canonicalDigest(local)

      let manifest = readExportManifest(artifact)
      check manifest.present
      checkpoint(manifest.detail)
      check manifest.ok
      check manifest.format == exportManifestFormat
      check manifest.policy == policy
      check manifest.policyText == $policy
      check manifest.categories == activeCategories(policy)
      check manifest.sourceDigest == report.sourceDigest
      check manifest.cellsRewritten == report.cellsRewritten
      manifests[policy] = manifest

    # THE THREE POLICIES ARE TOLD APART BY THE ARTIFACT ALONE. An
    # implementation recording a constant would fail here whichever
    # constant it chose.
    check manifests[rpNone].policy != manifests[rpDefault].policy
    check manifests[rpDefault].policy != manifests[rpStrict].policy
    check manifests[rpNone].categories == {}
    check manifests[rpNone].cellsRewritten == 0
    check manifests[rpDefault].categories < manifests[rpStrict].categories
    check manifests[rpDefault].cellsRewritten > 0
    check manifests[rpStrict].cellsRewritten >
      manifests[rpDefault].cellsRewritten

    # "NOT ACTIVATED" VERSUS "ACTIVATED AND MATCHED NOTHING". Both read as
    # a zero count, and a manifest that recorded only counts could not tell
    # them apart — which is why the active category set is recorded too.
    let plain = dir / "plain.sqlite"
    discard plainStore(plain)
    let plainArtifact = dir / "plain-export.sqlite"
    discard exportOf(plain, plainArtifact, rpDefault)
    let plainManifest = readExportManifest(plainArtifact)
    checkpoint(plainManifest.detail)
    check plainManifest.ok
    check rcBranch in plainManifest.categories
    check plainManifest.counts[rcBranch] == 0
    check rcBranch in manifests[rpDefault].categories
    check manifests[rpDefault].counts[rcBranch] == 1
    check rcRevision notin manifests[rpDefault].categories
    check manifests[rpDefault].counts[rcRevision] == 0
    check rcRevision in manifests[rpStrict].categories
    check manifests[rpStrict].counts[rcRevision] == 1

    # A MANIFEST THAT CANNOT BE READ IS A THIRD STATE, not either of the
    # other two. Both fixtures need a client reaching past this library.
    let broken = dir / "broken.sqlite"
    discard exportOf(local, broken, rpDefault)
    check runSqlite(broken, "update " & exportManifestTable &
      " set value = 'paranoid' where key = 'policy';").ok
    let brokenManifest = readExportManifest(broken)
    check brokenManifest.present
    check not brokenManifest.ok
    check "unknown redaction policy" in brokenManifest.detail

    let truncated = dir / "truncated.sqlite"
    discard exportOf(local, truncated, rpDefault)
    check runSqlite(truncated, "delete from " & exportManifestTable &
      " where key = 'policy.categories';").ok
    let truncatedManifest = readExportManifest(truncated)
    check truncatedManifest.present
    check not truncatedManifest.ok
    check "missing a required key" in truncatedManifest.detail

  # -------------------------------------------------------------------
  test "the default policy redacts its categories and keeps everything else":
    let dir = scratchDir("default")
    defer: removeDir(dir)
    let local = dir / "local.sqlite"
    let store = buildLocalStore(dir, local)
    let artifact = dir / "export.sqlite"
    let report = exportOf(local, artifact, rpDefault)

    # ---- THE POSITIVE CONTROLS COME FIRST, deliberately. Every absence
    # below is satisfied by an empty file, so the artifact is shown to be a
    # full copy before anything is asserted to be missing.
    check rowCounts(artifact) == rowCounts(local)
    check rowCounts(local).len >= 8
    for table in ["hosts", "host_profiles", "runs", "executions",
                  "ambient_samples", "extension_registry",
                  carriedExtensionTable, extensionTableName(knownExtension)]:
      check (table & "=0") notin rowCounts(artifact)
    check scalar(artifact, "select sum(duration_millis) from executions;") ==
      scalar(local, "select sum(duration_millis) from executions;")
    check scalar(artifact, "select sum(wall_millis) from " &
      extensionTableName(knownExtension) & ";") ==
      scalar(local, "select sum(wall_millis) from " &
      extensionTableName(knownExtension) & ";")

    # ---- THE SECRETS ARE GONE, from the whole FILE and not only from the
    # columns a reader would think to check.
    for secret in [secretAbsolutePath, secretWindowsPath, secretHomePath,
                   secretWorkspace, secretBranch, secretCommand,
                   secretExtPath, secretCarriedPath]:
      check not fileHolds(artifact, secret)
    # AND THE CONTROL FOR THAT SCAN: it finds them all in the local store,
    # so "not found" is a fact about the artifact rather than about the
    # scanner.
    for secret in everySecret:
      check fileHolds(local, secret)

    # ---- EACH CATEGORY, NAMED, at the column it applies to.
    let exported = openObservationStore(artifact)
    checkpoint(exported.report)
    check exported.captureEnabled
    # Three runs: the two this machine recorded and one that arrived with
    # the vendor merge.
    let runs = exported.readRuns()
    check runs.len == 4
    var first = runs[0]
    var second = runs[0]
    var third = runs[0]
    for row in runs:
      if row.runId == "run-1": first = row
      if row.runId == "run-2": second = row
      if row.runId == secretIdPath: third = row
    check first.runId == "run-1"
    check second.runId == "run-2"

    check first.gitBranch.get.startsWith(redactionTokenPrefix & "branch:")
    check first.gitBranch.get == redactionToken(rcBranch, secretBranch)
    check first.workspaceId.get ==
      redactionToken(rcWorkspace, secretWorkspace)
    # A PATH IN A COLUMN NOTHING CLASSIFIES AS ONE. `tool` is specified as
    # "free-form, client-declared" and `workspace_id` as "not a path", and
    # a column-scoped path rule would have left this alone. This is the
    # clause that says path redaction is applied where paths can BE, not
    # where they were expected.
    check first.tool == redactionToken(rcPath, secretAbsolutePath)
    # AND ITS CONVERSE: the relative path in the same column is untouched
    # by `default`, so the arm above is not "rewrite `tool` always".
    check second.tool == secretRelativePath

    # THE LIMIT, AS A MEASURED PAIR RATHER THAN A SENTENCE. One string, in
    # two columns of one row: rewritten in `tool`, left alone in `run_id`,
    # because `run_id` is part of the primary key and `executions` joins
    # through it. A rewritten key is a broken join, and the spine's ids are
    # specified as opaque and machine-generated so that this costs nothing
    # — but a client that puts a path in one has disclosed it, and that is
    # asserted here rather than left to be discovered.
    check third.runId == secretIdPath
    check third.tool == redactionToken(rcPath, secretIdPath)
    check fileHolds(artifact, secretIdPath)

    # EVERY command stats id, on every run, is a token — and still inside
    # the protocol's 64-byte bound, which a rewriting that grew the value
    # would break at the column's own check constraint.
    let executions = exported.readExecutions()
    check executions.len == 5
    var redactedCommands = 0
    for row in executions:
      check row.commandStatsId.len <= 64
      let source =
        if row.runId == "run-1": secretCommand
        elif row.runId == "run-2": "cmd-plain"
        else: "vendor-cmd"
      check row.commandStatsId == redactionToken(rcCommand, source)
      inc redactedCommands
    check redactedCommands == 5

    # THE PRODUCT'S OWN COLUMNS: the path inside one is redacted, because
    # a text value is scannable; the BRANCH NAME beside it is not, because
    # RunQuota may not interpret an extension column (OS-5). That hole is
    # asserted rather than left to be discovered, and `strict` closes it.
    let labels = exported.readExtensionColumns(knownExtension,
      ["action_label", "branch_label", "log_path"])
    check labels.len == 3
    var sawExtPath = false
    var sawExtBranch = false
    var sawWindows = false
    for row in labels:
      if row[0].startsWith(redactionTokenPrefix & "path:"):
        sawExtPath = true
      if row[1] == secretExtBranch:
        sawExtBranch = true
      if row[2].startsWith(redactionTokenPrefix & "path:"):
        sawWindows = true
      check secretExtPath notin row[0]
      check secretWindowsPath notin row[2]
    check sawExtPath
    check sawExtBranch
    check sawWindows

    # THE CARRIED PAYLOAD IS OPAQUE HEX, so the scanner is blind inside it
    # and `default` replaces it whole.
    let carried = exported.carriedExtensionRows(vendorExtension)
    check carried.len == 1
    check carried[0].startsWith(redactionTokenPrefix & "extension:")
    # And the local store's copy still reads out in full.
    check secretCarriedPath.toHex() in store.carriedExtensionRows(
      vendorExtension)[0]

    # ---- WHAT `default` DOES NOT TOUCH, which is what a policy redacting
    # EVERYTHING would destroy. Without these, "redact all" satisfies every
    # clause in this milestone's gate.
    check first.toolVersion == "2.14.0"
    check first.invocationKind == "build"
    check first.gitCommit.get == secretCommit
    check first.profile.get == secretProfile
    check first.captureCompleteness == ccComplete
    for row in executions:
      check row.termination == tExited
      check row.captureCompleteness == ccComplete
      # OS-6's dimension survives the export: every execution still names
      # the hardware profile it ran on, and it is the right one.
      check row.hostProfileId.isSome
      if row.hostId == localHost:
        check row.hostProfileId.get == localProfile
      else:
        check row.hostProfileId.get == vendorProfile
    let profiles = exported.readHostProfiles()
    check profiles.len == 2
    for row in profiles:
      check row.cpuModel == "Apple M2 Max"
      check row.logicalCores == 12
      check row.ramBytes == 1 shl 36
      check row.diskClass == dcNvme
      check row.fsType == "apfs"
    check exported.readAmbientSamples() == store.readAmbientSamples()
    # THE KEYS SURVIVE, which is what keeps the artifact joinable — and is
    # also the documented limit: a path in a key column would not be
    # redacted.
    check exported.readHosts().len == 2
    for row in executions:
      check row.runId in ["run-1", "run-2", "run-vendor"]
      check row.hostId in [localHost, vendorHost]

    # ---- THE ARTIFACT IS STILL MERGEABLE, which is what an export across
    # a trust boundary is FOR: the receiving side's operation is `merge`,
    # and §"Redaction" is a subsection of the merge chapter.
    let receiver = dir / "receiver.sqlite"
    let merged = mergeObservationStores(receiver, artifact)
    check merged.outcome == moMerged
    check merged.executionsAdded == 5
    check merged.hostsAdded == 2
    check merged.hostProfilesAdded == 2

    check report.counts[rcBranch] == 1
    check report.counts[rcWorkspace] == 1
    check report.counts[rcCommand] == 5
    check report.counts[rcPath] >= 4
    check report.counts[rcRelativePath] == 0
    check report.counts[rcRevision] == 0

    # ---- AND IT IS STILL IMMUTABLE: OS-3's trigger survived the export's
    # trigger surgery. Asserted LAST because the refusal degrades this
    # handle — `execute` reads a `raise(abort)` that is not a constraint
    # violation as a store that has stopped working, which is the existing
    # OS-4 behaviour and not this milestone's to change.
    check not exported.runStatement("update executions set exit_status = 9;")
    check "immutable" in exported.lastError.toLowerAscii
    check not exported.captureEnabled
    # The row did not move, which is what the refusal was for.
    check scalar(artifact, "select sum(exit_status) from executions;") == "0"

  # -------------------------------------------------------------------
  test "none really is none, and strict is strictly more than default":
    let dir = scratchDir("policies")
    defer: removeDir(dir)
    let local = dir / "local.sqlite"
    discard buildLocalStore(dir, local)

    # ---- `none`. THE CONVERSE THAT KEEPS EVERY OTHER ARM HONEST: without
    # it, an export pipeline that produced an empty or broken artifact
    # would satisfy all the absence clauses above.
    let untouched = dir / "none.sqlite"
    discard exportOf(local, untouched, rpNone)
    for secret in everySecret:
      check fileHolds(untouched, secret)
    # And it is the SAME database, table for table and cell for cell, apart
    # from the manifest it gained.
    check dumpWithout(untouched, exportManifestTable) ==
      dumpWithout(local, exportManifestTable)

    # ---- `strict` ⊋ `default`, asserted on the four things that differ.
    let strict = dir / "strict.sqlite"
    let strictReport = exportOf(local, strict, rpStrict)
    for secret in everySecret:
      check not fileHolds(strict, secret)

    let strictStore = openObservationStore(strict)
    checkpoint(strictStore.report)
    check strictStore.captureEnabled
    let runs = strictStore.readRuns()
    var first = runs[0]
    var second = runs[0]
    for row in runs:
      if row.runId == "run-1": first = row
      if row.runId == "run-2": second = row
    check first.runId == "run-1"
    check second.runId == "run-2"
    # THE KEY LIMIT HOLDS AT `strict` TOO — it is structural, not a
    # weakness of the weaker policy.
    var thirdRun = runs[0]
    for row in runs:
      if row.runId == secretIdPath: thirdRun = row
    check thirdRun.runId == secretIdPath
    check thirdRun.tool == redactionToken(rcPath, secretIdPath)
    check first.gitCommit.get == redactionToken(rcRevision, secretCommit)
    check first.profile.get == redactionToken(rcProfile, secretProfile)
    check second.tool == redactionToken(rcRelativePath, secretRelativePath)
    # THE HOLE `default` LEAVES IS CLOSED HERE: the branch name in a
    # product-owned column, which `default` cannot classify without
    # interpreting an extension column, is gone. A NULL stays NULL —
    # redacting an absence would invent a value the store deliberately
    # records as never having been supplied.
    let labels = strictStore.readExtensionColumns(knownExtension,
      ["branch_label"])
    check labels.len == 3
    var redactedBranches = 0
    var nullBranches = 0
    for row in labels:
      if row[0] == nullMarker:
        inc nullBranches
      else:
        check row[0] == redactionToken(rcExtension, secretExtBranch)
        inc redactedBranches
    check redactedBranches == 2
    check nullBranches == 1
    check strictReport.counts[rcExtension] >= 4
    check strictReport.counts[rcRelativePath] >= 1

    # ---- AND STRICT IS STILL NOT "REDACT EVERYTHING". The numbers, the
    # hardware dimension and the enumerated columns are all still there; a
    # policy that took them too would leave an artifact carrying nothing,
    # and this is where that is caught.
    check rowCounts(strict) == rowCounts(local)
    check scalar(strict, "select sum(duration_millis) from executions;") ==
      scalar(local, "select sum(duration_millis) from executions;")
    check scalar(strict, "select sum(wall_millis) from " &
      extensionTableName(knownExtension) & ";") ==
      scalar(local, "select sum(wall_millis) from " &
      extensionTableName(knownExtension) & ";")
    check strictStore.readHostProfiles().len == 2
    for row in strictStore.readHostProfiles():
      check row.cpuModel == "Apple M2 Max"
      check row.ramBytes == 1 shl 36
      check row.logicalCores == 12
    check strictStore.readAmbientSamples().len == 1
    check strictStore.readAmbientSamples()[0].cpuBusyPct == 41.5
    check strictStore.readExecutions().len == 5
    for row in strictStore.readExecutions():
      check row.termination == tExited
      check row.captureCompleteness == ccComplete
      check row.hostProfileId.isSome
      if row.hostId == localHost:
        check row.hostProfileId.get == localProfile
      else:
        check row.hostProfileId.get == vendorProfile
    check first.toolVersion == "2.14.0"
    check first.invocationKind == "build"
    check mergeObservationStores(dir / "receiver.sqlite", strict).outcome ==
      moMerged

  # -------------------------------------------------------------------
  test "redaction is applied at export and never at capture":
    let dir = scratchDir("capture")
    defer: removeDir(dir)
    let local = dir / "local.sqlite"
    let store = buildLocalStore(dir, local)

    # THE INSTRUMENT IS M15'S CANONICAL FORM: total over everything
    # observable, insensitive only to physical layout. If an export
    # rewrote so much as one cell of the local store, this moves.
    let before = canonicalDigest(local)
    check before.len == 64

    for policy in RedactionPolicy:
      let artifact = dir / ("out-" & $policy & ".sqlite")
      discard exportOf(local, artifact, policy)
      check canonicalDigest(local) == before

    # Three exports later, the developer's own store still answers in full
    # through the library's ordinary read path — the digest says nothing
    # moved, and this says what did not move.
    var runs = store.readRuns()
    var first = runs[0]
    if first.runId != "run-1":
      first = runs[1]
    check first.tool == secretAbsolutePath
    check first.workspaceId.get == secretWorkspace
    check first.gitBranch.get == secretBranch
    check first.gitCommit.get == secretCommit
    check first.profile.get == secretProfile
    check store.readExecutions()[0].commandStatsId == secretCommand
    check store.readExtensionColumns(knownExtension, ["action_label"]).len == 3
    check secretExtPath in $store.readExtensionColumns(knownExtension,
      ["action_label"])
    check secretExtBranch in $store.readExtensionColumns(knownExtension,
      ["branch_label"])
    for secret in everySecret:
      check fileHolds(local, secret)

    # A LOCAL STORE STILL DECLARES NOTHING, so nobody downstream can read
    # it as an artifact that was already redacted.
    check not readExportManifest(local).present

    # AND THE ONE CALL THAT COULD LEGITIMISE REDACT-IN-PLACE IS REFUSED.
    let onto = exportObservationStore(local, local, rpStrict)
    check onto.outcome == xoDestinationIsSource
    check canonicalDigest(local) == before

  # -------------------------------------------------------------------
  test "an export is deterministic, and refuses what it cannot do":
    let dir = scratchDir("determinism")
    defer: removeDir(dir)
    let local = dir / "local.sqlite"
    discard buildLocalStore(dir, local)

    # TWO EXPORTS OF ONE STORE ARE THE SAME DATABASE. Without it a receiver
    # merging two shipments of the same history would count every row
    # twice, which is OS-7 lost at the trust boundary rather than in the
    # merge.
    let firstPath = dir / "first.sqlite"
    let secondPath = dir / "second.sqlite"
    let firstReport = exportOf(local, firstPath, rpDefault)
    let secondReport = exportOf(local, secondPath, rpDefault)
    check canonicalDigest(firstPath) == canonicalDigest(secondPath)
    check firstReport.cellsRewritten == secondReport.cellsRewritten
    check firstReport.sourceDigest == secondReport.sourceDigest

    let receiverPath = dir / "receiver.sqlite"
    check mergeObservationStores(receiverPath, firstPath).outcome == moMerged
    let again = mergeObservationStores(receiverPath, secondPath)
    check again.outcome == moMerged
    check again.executionsAdded == 0
    check again.carriedRowsAdded == 0
    # THE CONTROL: the first merge really did carry rows, so the zero above
    # is idempotence and not an empty artifact.
    check openObservationStore(receiverPath).readExecutions().len == 5

    # REFUSALS, each leaving the source exactly as it was.
    let digest = canonicalDigest(local)
    check exportObservationStore(local, firstPath, rpDefault).outcome ==
      xoDestinationExists
    check canonicalDigest(firstPath) == canonicalDigest(secondPath)
    check exportObservationStore(dir / "absent.sqlite",
      dir / "x.sqlite", rpDefault).outcome == xoSourceUnreadable
    let garbage = dir / "garbage.sqlite"
    writeFile(garbage, "this is not a database, it is a sentence")
    check exportObservationStore(garbage, dir / "y.sqlite",
      rpDefault).outcome == xoSourceUnreadable
    check not fileExists(dir / "x.sqlite")
    check not fileExists(dir / "y.sqlite")
    check canonicalDigest(local) == digest

    # AND THE CONVERSE, without which "refuse everything" would pass: the
    # same source exports fine to a name nobody has used.
    check exportObservationStore(local, dir / "third.sqlite",
      rpDefault).outcome == xoExported

  # -------------------------------------------------------------------
  test "the copy that cannot be written, and no sqlite3 at all":
    # TWO REFUSAL ARMS NO WELL-BEHAVED CALLER REACHES, and neither is
    # expensive to reach on purpose. An arm nothing exercises is an arm
    # nobody knows the shape of.
    let dir = scratchDir("refusals")
    defer: removeDir(dir)
    let local = dir / "local.sqlite"
    discard buildLocalStore(dir, local)
    let digest = canonicalDigest(local)

    # THE COPY ITSELF CANNOT BE MADE. `vacuum into` fails before one cell
    # has been rewritten, so the refusal names the WRITE and not the
    # redaction, and there is nothing on disk to mistake for an artifact.
    let unwritable = dir / "no-such-directory" / "out.sqlite"
    let failed = exportObservationStore(local, unwritable, rpDefault)
    check failed.outcome == xoFailed
    check "could not write" in failed.detail
    check not fileExists(unwritable)
    check canonicalDigest(local) == digest

    # NO `sqlite3` ON PATH AT ALL — OS-4's condition, and the reason this
    # library reaches SQLite through the tool rather than a linked
    # library. Both entry points have this arm and both must take it.
    let savedPath = getEnv("PATH")
    defer: putEnv("PATH", savedPath)
    putEnv("PATH", dir / "no-tools-here")
    check not sqliteToolAvailable()
    let unavailable = exportObservationStore(local, dir / "u.sqlite",
      rpDefault)
    check unavailable.outcome == xoUnavailable
    check "not on PATH" in unavailable.detail
    check not fileExists(dir / "u.sqlite")
    # AND THE READER'S SAME ARM, which is where it matters most: a store
    # NOBODY COULD LOOK AT must not read as a store that carries no
    # manifest. Both answer `present == false`, so the two are told apart
    # by `detail` and that is asserted here rather than assumed.
    let blind = readExportManifest(local)
    check not blind.present
    check not blind.ok
    check "not on PATH" in blind.detail
    putEnv("PATH", savedPath)
    check sqliteToolAvailable()
    let sighted = readExportManifest(local)
    check not sighted.present
    check "no export manifest" in sighted.detail
    check "not on PATH" notin sighted.detail

  # -------------------------------------------------------------------
  test "a table the pass cannot address is refused, not silently skipped":
    # THE ONE BRANCH A WELL-BEHAVED CLIENT REACHES BY BEING WELL BEHAVED.
    # The pass addresses rows by `rowid`, and a product is entitled to
    # declare its extension table `without rowid` — the shape gate asks for
    # the two key columns and a foreign key, and this has both. A pass that
    # SKIPPED such a table would report a policy it had not applied
    # everywhere, which is the quiet failure this milestone exists to
    # forbid; so the export refuses as a whole and leaves nothing behind.
    let dir = scratchDir("norowid")
    defer: removeDir(dir)
    let local = dir / "local.sqlite"
    discard buildLocalStore(dir, local)

    const rowidlessId = "m16x_rowidless"
    const rowidlessDdl = """
create table ext_m16x_rowidless (
  host_id text not null,
  execution_id text not null,
  label text not null,
  primary key (host_id, execution_id),
  foreign key (host_id, execution_id)
    references executions(host_id, execution_id)
) without rowid;
"""
    let store = openObservationStore(local)
    check store.captureEnabled
    let declaration = ExtensionDeclaration(extensionId: rowidlessId,
      owner: fixtureOwner, schemaVersion: 1, migrations: @[rowidlessDdl])
    # The declaration is ACCEPTED — this is a legal extension, not a
    # malformed one, which is what makes the refusal below load-bearing.
    check store.declareExtension(declaration) == eoCreated
    check store.insertExtensionRow(declaration, ExtensionRow(
      hostId: localHost, executionId: "exec-1", columns: @["label"],
      values: @[extText(secretAbsolutePath)])) == ewWritten

    let artifact = dir / "export.sqlite"
    let report = exportObservationStore(local, artifact, rpDefault)
    check report.outcome == xoFailed
    check extensionTableName(rowidlessId) in report.detail
    # NOTHING IS LEFT BEHIND. A half-redacted artifact on disk is worse
    # than no artifact: somebody would ship it.
    check not fileExists(artifact)
    # And `none`, which rewrites nothing, still works on the same store —
    # so the refusal is about the REWRITE and not about the table.
    check exportObservationStore(local, dir / "none.sqlite",
      rpNone).outcome == xoExported
    check fileHolds(dir / "none.sqlite", secretAbsolutePath)
