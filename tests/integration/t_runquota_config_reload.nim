## `runquota config` against a real `runquotad`: the verb writes the host
## budget file, the daemon reloads it, and leases already in flight are
## treated the way `reprobuild-specs/RunQuota-Host-Configuration.md`
## ("Changing it under a running daemon") decides.
##
## A PRIVATE DAEMON AND A PRIVATE FILE, ALWAYS. The daemon is started with
## `--socket` on a scratch endpoint and `--host-config` on a scratch file, and
## every CLI invocation passes `--file` for the same file and reaches the
## daemon through `RUNQUOTA_SOCKET`. Nothing here reads, writes or reloads the
## host's real `runquotad.toml`, and nothing talks to the host's daemon: a
## test that did would change the budget of every workspace on the machine.
##
## NO MOCKS. The shipped `runquota` and `runquotad` binaries, a real endpoint,
## real files; the leases are taken with the real client library.

import std/[os, osproc, streams, strutils, unittest]

from runquota_ipc import endpointDirectoryPermissions, endpointForPath
import runquota_client
import runquota_core
import daemon_binary
import daemon_endpoint
from runquota_core/child_process import runCapturedProcess
import scratch_root

const GiB = 1024'u64 * 1024'u64 * 1024'u64

proc scratchRoot(name: string): string =
  result = getTempDir() / ("rq-hostcfg-" & $getCurrentProcessId() & "-" & name)
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

type DaemonHandle = object
  process: Process

proc startDaemon(socketPath, hostConfig, stateDir: string;
                 extraArgs: openArray[string] = []): DaemonHandle =
  var args = @["--socket", socketPath, "--host-config", hostConfig,
    "--host-identity-file", stateDir / "host-id",
    "--ambient-sample-interval-millis", "0", "--no-write-stats",
    # Admission here must depend on the ledger alone, not on how busy this
    # machine happens to be.
    "--memory-pressure-source", "unavailable"]
  for arg in extraArgs:
    args.add(arg)
  let process = startProcess(daemonPath(), args = args,
    options = {poStdErrToStdOut})
  for _ in 0 ..< 400:
    if endpointIsBound(socketPath): break
    sleep(25)
  doAssert endpointIsBound(socketPath), "runquotad did not bind " & socketPath
  for _ in 0 ..< 3:
    discard process.outputStream.readLine()
  DaemonHandle(process: process)

proc stop(handle: var DaemonHandle) =
  if handle.process.running:
    handle.process.terminate()
    discard handle.process.waitForExit(5000)
  if handle.process.running:
    handle.process.kill()
    discard handle.process.waitForExit(5000)
  handle.process.close()

type CliResult = object
  output: string
  code: int

proc runCli(args: varargs[string]): CliResult =
  var argv: seq[string] = @[]
  for arg in args:
    argv.add(arg)
  let captured = runCapturedProcess(cliPath(), argv, options = {})
  doAssert captured.failure.len == 0, captured.failure
  result = CliResult(output: captured.output & captured.error,
    code: captured.exitCode)
  checkpoint "runquota " & argv.join(" ") & " -> " & $result.code & "\n" &
    result.output

proc request(label: string; memoryGiB: uint64): ResourceRequest =
  resourceRequest(label, milliCpu(1000), bytes(memoryGiB * GiB))

proc offerOne(session: var RunQuotaSession; id: uint64; label: string;
              memoryGiB: uint64): OfferedLease =
  let decisions = session.offerCandidates([toCandidate(id,
    request(label, memoryGiB))])
  doAssert decisions.len == 1
  decisions[0]

proc pollFor(session: var RunQuotaSession; id: uint64): OfferedLease =
  ## The decision for candidate `id`, from `GrantNext`.
  for _ in 0 ..< 40:
    for decision in session.pollNextGrant():
      if decision.clientCandidateId == id:
        return decision
    sleep(25)
  doAssert false, "no decision for candidate " & $id

suite "runquota config and a running daemon":

  test "set writes the file, the daemon reloads, and leases follow the rule":
    let root = scratchRoot("reload")
    defer: removeScratchRoot(root)
    let socket = rendezvousDir(root) / "d.sock"
    let state = hostStateDir(root)
    let file = root / "etc" / "runquotad.toml"
    createDir(root / "etc")
    putEnv("RUNQUOTA_SOCKET", socket)

    # The first write starts from the template, into a directory the "install
    # step" (this test) provisioned. No daemon runs yet, which is not an error.
    let first = runCli("config", "set", "machine.memory_bytes", "8GiB",
      "--file", file)
    check first.code == 0
    check "wrote " & file in first.output
    check "no runquotad answers" in first.output
    check "memory_bytes = 8589934592   # 8 GiB" in readFile(file)
    check "# RunQuota host budget." in readFile(file)

    var daemon = startDaemon(socket, file, state)
    defer: daemon.stop()
    var client = connect(endpointForPath(socket))
    defer: client.close()
    var one = client.registerSession("one", "1")
    var two = client.registerSession("two", "1")

    var held = one.offerOne(1, "held", 6)
    check held.lease.active and not held.queued
    let waiting = two.offerOne(2, "waiting", 6)
    check waiting.queued

    # ---- GROW: the queued lease is granted by the reload ---------------
    let grow = runCli("config", "set", "machine.memory_bytes", "16GiB",
      "--file", file)
    check grow.code == 0
    check "runquotad reloaded its host configuration" in grow.output
    check "memory_bytes = 17179869184 (16 GiB)" in grow.output
    check "1 queued lease(s) granted" in grow.output
    check "from " & file in grow.output
    var promoted = two.pollFor(2)
    check promoted.lease.active and not promoted.queued

    # ---- SHRINK: granted leases stay granted ---------------------------
    # 12 GiB is held now. A 5 GiB request fits 16 but not what is left, so it
    # queues, and a 14 GiB one queues too; then the budget drops to 8 GiB.
    let small = one.offerOne(3, "small", 5)
    check small.queued
    let doomed = two.offerOne(4, "doomed", 14)
    check doomed.queued
    let shrink = runCli("config", "set", "machine.memory_bytes", "8GiB",
      "--file", file)
    check shrink.code == 0
    check "memory_bytes = 8589934592 (8 GiB)" in shrink.output
    check "over the new budget" in shrink.output
    # Both granted leases are still the daemon's, and still releasable.
    let status = client.daemonStatus()
    check status.activeLeases == 2'u32
    # The 14 GiB request can never fit 8 GiB: denied, not left waiting.
    let denial = two.pollFor(4)
    check not denial.lease.active
    check denial.diagnostic.message ==
      "lease request exceeds machine memory budget: local"
    # The 5 GiB one fits 8 GiB but not while 12 GiB is held: still queued.
    var stillQueued = true
    for decision in one.pollNextGrant():
      if decision.clientCandidateId == 3'u64:
        stillQueued = decision.queued
    check stillQueued
    # Releasing brings the held total under the new budget, and admits it.
    held.lease.release()
    promoted.lease.release()
    let admitted = one.pollFor(3)
    check admitted.lease.active and not admitted.queued

    # ---- A request larger than the new budget is refused outright ------
    let tooBig = one.offerOne(5, "too-big", 9)
    check not tooBig.lease.active
    check tooBig.diagnostic.message ==
      "lease request exceeds machine memory budget: local"

    # ---- A hand edit that does not parse changes nothing ---------------
    writeFile(file, readFile(file) & "[network]\n")
    let broken = runCli("config", "reload")
    check broken.code == 1
    check "runquotad did not reload" in broken.output
    check file & ":" in broken.output
    check "unknown table" in broken.output
    check "budget in force is unchanged" in broken.output
    let show = runCli("config", "show", "--file", file)
    check "memory_bytes = 8589934592 (8 GiB)" in show.output
    check "read from: " & file in show.output
    # And `config set` refuses to build on a file it cannot read.
    let refused = runCli("config", "set", "pools.compile", "2", "--file", file)
    check refused.code == 1
    check "unknown table" in refused.output

    # ---- unset returns a key to its default ----------------------------
    writeFile(file, "schema = \"runquota.host-config.v1\"\n[machine]\n" &
      "memory_bytes = 8589934592\n[pools]\ncompile = 2\n")
    check runCli("config", "reload").code == 0
    let unset = runCli("config", "unset", "pools.compile", "--file", file)
    check unset.code == 0
    check "pools compile" notin unset.output
    check "compile" notin readFile(file)
    check "memory_bytes = 8589934592" in readFile(file)

    var small3 = admitted
    small3.lease.release()
    one.closeSession()
    two.closeSession()

  test "a flag pins its key across a reload, and the verb says so":
    let root = scratchRoot("pinned")
    defer: removeScratchRoot(root)
    let socket = rendezvousDir(root) / "d.sock"
    let state = hostStateDir(root)
    let file = root / "runquotad.toml"
    putEnv("RUNQUOTA_SOCKET", socket)
    writeFile(file, "schema = \"runquota.host-config.v1\"\n")
    var daemon = startDaemon(socket, file, state,
      ["--memory-bytes", $(4'u64 * GiB)])
    defer: daemon.stop()
    let answer = runCli("config", "set", "machine.memory_bytes", "32GiB",
      "--file", file)
    check answer.code == 0
    check "memory_bytes = 4294967296 (4 GiB)" in answer.output
    check "pinned by runquotad flags" in answer.output
    check "machine.memory_bytes" in answer.output

  test "a file the daemon does not read is reported as not in force":
    let root = scratchRoot("elsewhere")
    defer: removeScratchRoot(root)
    let socket = rendezvousDir(root) / "d.sock"
    let state = hostStateDir(root)
    putEnv("RUNQUOTA_SOCKET", socket)
    var daemon = startDaemon(socket, root / "daemon.toml", state)
    defer: daemon.stop()
    let answer = runCli("config", "set", "machine.cpu_milli", "2000",
      "--file", root / "other.toml")
    check answer.code == 0
    check "not in force" in answer.output

  test "the verb never creates the host directory":
    let root = scratchRoot("unprovisioned")
    defer: removeScratchRoot(root)
    let file = root / "missing" / "runquotad.toml"
    putEnv("RUNQUOTA_SOCKET", root / "nobody.sock")
    let answer = runCli("config", "set", "machine.cpu_milli", "2000",
      "--file", file)
    check answer.code == 1
    check "does not exist" in answer.output
    check "install step" in answer.output
    check not dirExists(root / "missing")
    # A malformed key is a usage error of its own, reported before any IO.
    check runCli("config", "set", "machine.colour", "2", "--file",
      file).code == 1
    check runCli("config", "frobnicate").code == 2
