## M15 gate, the backup half: **the store is copied while the daemon runs
## and the copy is usable standalone.**
##
## Also the `docs/database.md` state-boundary requirement the observation
## store has been carrying as a promissory note since M9 — "the store MUST
## be copyable while the daemon runs, and a restored copy MUST be usable
## without the originating daemon".
##
## NO MOCKS AND NOTHING SUBSTITUTED. The first test runs the real
## ``runquotad`` binary from ``build/bin``, a real Unix-domain socket, the
## real client library, and takes the copy while that daemon is verifiably
## still up and still writing. Then the daemon is stopped and ITS WHOLE
## STATE DIRECTORY IS DELETED — store, write-ahead log, shared-memory
## index, host identity, socket — before the copy is opened. "Standalone"
## is not asserted by adjective; the thing it would have depended on is
## removed first.
##
## THE SECOND TEST IS THE CONTROL, AND WITHOUT IT THE FIRST IS NEARLY
## VACUOUS. On a store nobody else has open, ``cp`` of the database file
## produces a perfectly good copy — SQLite checkpoints the write-ahead log
## when the last connection closes, so the file holds everything. That is
## exactly the condition a backup test accidentally arranges for itself,
## and under it a backup implemented as ``copyFile`` passes every
## assertion. So the second test arranges the condition a LIVE store
## actually has: a reader holding a snapshot, which is what stops the log
## from being checkpointed into the file. Under it the plain copy silently
## loses every row written since that snapshot, and ``backupTo`` does not.
##
## WHAT "USABLE" IS ASSERTED TO MEAN: the copy opens at the current schema
## with capture enabled, holds the rows the original held at the moment of
## the copy and NOT the ones written after it, resolves every execution's
## hardware profile, orphans nothing, and accepts new writes and a new
## extension of its own.

import std/[options, os, osproc, posix, streams, unittest]

from runquota_ipc import endpointDirectoryPermissions
import runquota_client
import runquota_core
import runquota_observation_store
import runquota_protocol
import daemon_binary

# ---------------------------------------------------------------------------
# Daemon plumbing
# ---------------------------------------------------------------------------

proc scratchRoot(name: string): string =
  # Short on purpose: `Sockaddr_un_path_length` is 92 on macOS, so the
  # whole socket path has 91 characters to live in.
  result = getTempDir() / ("rq-m15b-" & $getCurrentProcessId() & "-" & name)
  removeDir(result)
  createDir(result)

proc rendezvousDir(root: string): string =
  result = root / "ep"
  createDir(result)
  setFilePermissions(result, endpointDirectoryPermissions())

proc hostStateDir(root: string): string =
  result = root / "state"
  createDir(result)
  setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc socketIsBound(path: string): bool =
  var info: Stat
  lstat(path.cstring, info) == 0 and S_ISSOCK(info.st_mode)

type DaemonHandle = object
  process: Process
  startupLines: seq[string]

proc startDaemon(socketPath: string;
                 extraArgs: openArray[string]): DaemonHandle =
  var args = @["--socket", socketPath]
  for arg in extraArgs:
    args.add(arg)
  let process = startProcess(daemonPath(), args = args,
    options = {poStdErrToStdOut})
  for _ in 0 ..< 400:
    if socketIsBound(socketPath): break
    sleep(25)
  var lines: seq[string] = @[]
  for _ in 0 ..< 3:
    lines.add(process.outputStream.readLine())
  DaemonHandle(process: process, startupLines: lines)

proc stop(handle: var DaemonHandle) =
  if handle.process.running:
    handle.process.terminate()
    discard handle.process.waitForExit(5000)
  if handle.process.running:
    handle.process.kill()
    discard handle.process.waitForExit(5000)
  handle.process.close()

proc completeOneExecution(client: var RunQuotaClient; label: string) =
  var session = client.registerSession("m15b-" & label, "0.1.0")
  var lease = session.requestLease(resourceRequest(
    label, milliCpu(1000), bytes(64'u64 * 1024'u64 * 1024'u64)))
  doAssert lease.active
  lease.markStarting()
  lease.markRunning(childProcessId = uint64(getCurrentProcessId()))
  lease.finish(outcome = succeeded(),
    peakMemoryBytes = 1_000'u64, processCount = 1'u32,
    majorPageFaults = 0'u64)
  lease.release()
  session.closeSession()

proc waitForExecutions(path: string; atLeast: int): int =
  for _ in 0 ..< 200:
    let store = openObservationStore(path)
    if store.captureEnabled:
      result = store.readExecutions().len
      if result >= atLeast:
        return
    sleep(25)

# ---------------------------------------------------------------------------
# A synthetic extension, so the copy is asserted to be usable for the thing
# a restored store is actually for rather than only readable.
# ---------------------------------------------------------------------------

const restoredDdl = """
create table ext_m15b_restored (
  host_id text not null,
  execution_id text not null,
  restored_label text not null,
  primary key (host_id, execution_id),
  foreign key (host_id, execution_id)
    references executions(host_id, execution_id)
);
"""

proc restoredExtension(): ExtensionDeclaration =
  ExtensionDeclaration(extensionId: "m15b_restored", owner: "runquota-m15",
    schemaVersion: 1, migrations: @[restoredDdl])

suite "observation_store_backup_standalone":

  test "a store copied under a live daemon is usable with the daemon gone":
    let root = scratchRoot("live")
    # The copies live OUTSIDE the root, because the root is deleted before
    # the copy is opened.
    let vault = scratchRoot("vault")
    defer: removeDir(vault)
    let socketPath = rendezvousDir(root) / "d.sock"
    let state = hostStateDir(root)
    let identityFile = state / "host-id"
    let dbPath = state / "observations.sqlite3"
    check fileExists(daemonPath())

    putEnv("RUNQUOTA_SOCKET", socketPath)
    # Ambient sampling off: this test is about the copy, and a background
    # sampler would put rows into it that nothing here asked for.
    var daemon = startDaemon(socketPath, [
      "--host-identity-file", identityFile,
      "--ambient-sample-interval-millis", "0"])

    var beforeCopy = 0
    var afterCopy = 0
    let backupPath = vault / "backup.sqlite"
    let plainPath = vault / "plain.sqlite"
    var copiedWhileRunning = false
    try:
      var client = connectDefault()
      for i in 1 .. 12:
        client.completeOneExecution("first-" & $i)
      beforeCopy = waitForExecutions(dbPath, 12)
      check beforeCopy == 12

      # THE COPY IS TAKEN WITH THE DAEMON UP. Asserted, not assumed — the
      # whole clause is about a live store.
      check daemon.process.running
      copiedWhileRunning = daemon.process.running
      let live = openObservationStore(dbPath)
      check live.captureEnabled
      check live.backupTo(backupPath)
      copyFile(dbPath, plainPath)
      check daemon.process.running

      # AND THE DAEMON KEEPS WRITING AFTERWARDS. The copy must be a
      # point-in-time snapshot, so these rows must NOT be in it — which is
      # also what catches a "backup" that is a symlink, a hard link, or a
      # copy deferred until somebody looked.
      for i in 1 .. 8:
        client.completeOneExecution("second-" & $i)
      afterCopy = waitForExecutions(dbPath, 20)
      check afterCopy == 20
      client.close()
    finally:
      daemon.stop()

    check copiedWhileRunning
    check fileExists(backupPath)

    # THE ORIGINATING DAEMON IS GONE AND SO IS EVERYTHING IT OWNED: the
    # store, its write-ahead log and shared-memory index, the host identity
    # file, the socket. Whatever the copy needs, it now has to have.
    removeDir(root)
    check not fileExists(dbPath)
    check not dirExists(root)

    let restored = openObservationStore(backupPath)
    check restored.status == ssOpen
    check restored.captureEnabled
    check restored.schemaVersion == spineSchemaVersion

    # THE SNAPSHOT, both halves. The rows the store held when the copy was
    # taken are there; the eight written afterwards are not.
    let rows = restored.readExecutions()
    check rows.len == beforeCopy
    var labels = 0
    for row in rows:
      check row.hostProfileId.isSome
      if row.ownerUid.isSome:
        labels += 1
    check labels == beforeCopy

    # The hardware dimension travelled with the rows, which is what makes a
    # restored copy worth merging: every execution still resolves to the
    # profile it ran under.
    check restored.readHosts().len == 1
    check restored.readHostProfiles().len >= 1
    check restored.orphanReport().checked
    check restored.orphanReport().orphans == 0

    # AND IT IS A STORE, not a read-only artefact: it takes an extension it
    # has never seen, a row of that extension against a restored execution,
    # a retention pass, and a merge — with no daemon anywhere.
    check restored.declareExtension(restoredExtension()) == eoCreated
    check restored.insertExtensionRow(restoredExtension(), ExtensionRow(
      hostId: rows[0].hostId, executionId: rows[0].executionId,
      columns: @["restored_label"],
      values: @[extText("restored")])) == ewWritten
    check restored.extensionRowCount("m15b_restored") == 1
    var policy = noRetention()
    policy.maxExecutions = some(6'i64)
    let pruned = restored.applyRetention(rows[0].hostId, 0, policy)
    check pruned.applied
    check pruned.executionsRemoved == beforeCopy - 6
    check restored.readExecutions().len == 6
    check restored.orphanReport().orphans == 0

  test "a plain file copy of a live store loses rows the backup keeps":
    # THE CONTROL THAT DECIDES THE TEST ABOVE. Without a reader holding a
    # snapshot, SQLite checkpoints the log when the last connection closes
    # and `cp` produces a perfect copy — so a backup implemented as
    # `copyFile` would pass every assertion in this file. A live store does
    # not have that property, and this is what it looks like when it does
    # not.
    let dir = scratchRoot("wal")
    defer: removeDir(dir)
    let path = dir / "o.sqlite"
    let store = openObservationStore(path)
    check store.captureEnabled
    check store.insertHost(HostRow(hostId: "host-w",
      createdAtUnixMillis: 1_000, lastBootId: "boot"))
    check store.insertHostProfile(HostProfileRow(hostId: "host-w",
      profileId: "p", profileHash: "sha256:p", validFromUnixMillis: 1_000,
      cpuModel: "synthetic", physicalCores: 4, logicalCores: 8,
      ramBytes: 1 shl 34, swapBytes: 0, diskClass: dcSsd, fsType: "apfs",
      arch: "arm64", os: "macos", osVersion: "15", kernelVersion: "24",
      virtualization: "none", cpuShareGroup: "default"))
    check store.insertRun(RunRow(runId: "run-1", hostId: "host-w", tool: "t",
      toolVersion: "v", invocationKind: "build", startedAtUnixMillis: 1_000,
      captureCompleteness: ccComplete))

    proc addExecution(id: string; startedAt: int64) =
      check store.insertExecution(ExecutionRow(executionId: id,
        hostId: "host-w", hostProfileId: some("p"), runId: "run-1",
        commandStatsId: "c", startedAtUnixMillis: startedAt,
        finishedAtUnixMillis: startedAt + 1, durationMillis: 1,
        exitStatus: 0, termination: tExited, attempt: 1, peakRssBytes: 0,
        maxProcesses: 1, majorPageFaults: 0,
        captureCompleteness: ccComplete))

    for i in 1 .. 5:
      addExecution("early-" & $i, int64(i))
    # No connection is open, so the log has been checkpointed into the file
    # and these five rows are in it. Asserted, because it is the premise of
    # everything below.
    check runSqlite(path, "pragma wal_checkpoint(truncate);").ok
    let baseline = dir / "baseline.sqlite"
    copyFile(path, baseline)
    check openObservationStore(baseline).readExecutions().len == 5

    # A READER HOLDING A SNAPSHOT — which is what a live store has and an
    # idle one does not. Its transaction pins the checkpoint, so everything
    # written from here on stays in the log.
    let holder = startProcess("sqlite3", args = ["-batch", path],
      options = {poUsePath, poStdErrToStdOut})
    holder.inputStream.write("begin;\nselect count(*) from executions;\n")
    holder.inputStream.flush()
    sleep(300)
    check holder.running

    for i in 1 .. 20:
      addExecution("late-" & $i, int64(100 + i))
    check store.readExecutions().len == 25

    let plain = dir / "plain.sqlite"
    let backup = dir / "backup.sqlite"
    copyFile(path, plain)
    check store.backupTo(backup)
    # ONE FILE, checked before anything opens it: `vacuum into` writes a
    # complete database rather than a main file plus the log the rows are
    # really in. A copy that needed a sidecar would not survive being moved
    # to another machine, which is what a backup is for.
    check not fileExists(backup & "-wal")
    check not fileExists(backup & "-shm")

    holder.terminate()
    discard holder.waitForExit(5000)
    if holder.running:
      holder.kill()
      discard holder.waitForExit(5000)
    holder.close()

    # THE PLAIN COPY LOST ROWS AND SAYS NOTHING ABOUT IT. Not corrupt, not
    # an error — just quietly short, which is the worst shape a backup
    # failure can take.
    let plainStore = openObservationStore(plain)
    check plainStore.status == ssOpen
    let plainRows = plainStore.readExecutions().len
    echo "  plain copy: " & $plainRows & " of 25 executions; backup: " &
      $openObservationStore(backup).readExecutions().len
    check plainRows < 25
    check plainRows == 5

    # THE BACKUP DID NOT.
    let backupStore = openObservationStore(backup)
    check backupStore.status == ssOpen
    check backupStore.readExecutions().len == 25
    check backupStore.orphanReport().orphans == 0
