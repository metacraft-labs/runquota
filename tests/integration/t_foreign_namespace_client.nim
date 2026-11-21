## A client in other namespaces than the daemon's: a container's build
## reaching the host daemon through a forwarded or mounted socket.
##
## Such a client knows itself by its own namespace's ids: `getuid()` is a
## container uid, and the pids it reports are container pids. The daemon
## reads the connection's peer credentials in its own namespaces. This file
## checks the two things that follow (`runquota_protocol/client_namespaces`):
##
## * the client is SERVED, as the uid the kernel names (its owner is the
##   peer credential, never the uid it declared), in the session group it
##   asked for -- rather than refused for "declaring somebody else";
## * the child it reports is NOT probed by its foreign pid. The daemon
##   watches the connection's peer process in its place, so a lost
##   supervisor's lease is released when that process is gone instead of
##   being pinned by an unrelated host process that happens to wear the
##   container-local pid (pid 2 inside is the host's `kthreadd`, which never
##   exits).
##
## THE NAMESPACES ARE REAL. The client is the shipped `runquota` CLI run
## under `unshare --user --map-root-user --mount --pid --fork --mount-proc`:
## a new user namespace in which this test's uid is root, and a new pid
## namespace in which the CLI is pid 1. It reaches the daemon's socket
## directly (the same mount namespace's files), which is how a socket bound
## into a container arrives; the incus proxy device that forwards one is
## covered against real Incus by gosti's
## `tests/e2e/t_incus_runquota_host_budget.nim`.
##
## * a client on the HOST that claims other namespaces -- to be excused from
##   the declared-uid refusal, or to have its connection watched in its
##   child's place -- is refused, because the daemon checks the claim against
##   what the kernel shows of the peer (`runquota_daemon/peer_namespaces`).
##
## No mocks. Every process is one this file started (or the namespace init
## that `unshare` forked for it, found through `/proc/<unshare>/task/*/children`
## and signalled only by that recorded pid); nothing else is signalled.
## Linux only; elsewhere every case is reported skipped. A host that does not
## allow unprivileged user namespaces fails the prerequisite loudly.

when not defined(linux):
  import std/unittest
  suite "foreign_namespace_client":
    test "a client in its own user and pid namespace is served as its host uid":
      skip()
    test "a lost supervisor in another pid namespace does not pin its lease":
      skip()
    test "a host client cannot claim another namespace to skip a check":
      skip()
else:
  import std/[json, os, osproc, posix, streams, strtabs, strutils, times, unittest]

  import runquota_core
  import runquota_ipc
  import runquota_protocol

  import daemon_binary
  import private_daemon_fixture
  import host_true_command

  const BudgetMilli = 2000

  let unshareExe = findExe("unshare")

  proc nsArgs(command: seq[string]): seq[string] =
    ## `--kill-child`: should this test stop the `unshare` it started, the
    ## kernel ends the namespace's init (and so the whole namespace) too.
    @["--user", "--map-root-user", "--mount", "--pid", "--fork",
      "--kill-child", "--mount-proc"] & command

  proc namespaceInit(unsharePid: int): int =
    ## The process `unshare --fork` started: pid 1 of the new pid namespace,
    ## named here by its HOST pid. 0 until it exists.
    for task in walkDir("/proc/" & $unsharePid & "/task"):
      let children = try: readFile(task.path / "children").strip()
                     except IOError: ""
      for child in children.splitWhitespace():
        return parseInt(child)
    0

  proc leasesJson(env: StringTableRef): JsonNode =
    let (code, text) = cli(env, ["leases", "--json"])
    if code != 0: return newJArray()
    try: parseJson(text)["leases"]
    except CatchableError: newJArray()

  proc waitRunningLease(env: StringTableRef; budgetMillis: int): JsonNode =
    let deadline = epochTime() + budgetMillis / 1000
    while epochTime() < deadline:
      for lease in leasesJson(env):
        if lease["state"].getStr == "running":
          return lease
      sleep(50)
    newJNull()

  proc exchangeHello(socketPath: string; processId, userId: uint64;
                     capabilities: string):
      tuple[kind: RqspMessageKind; diagnostic: Diagnostic] =
    ## Speaks the wire protocol directly: the shipped client only ever
    ## reports its real namespaces, so it cannot express the lie these cases
    ## are about. This process is the connection's peer.
    # The private policy the fixture gives every client of this daemon, set
    # for this process because the probe connects from here.
    putEnv("RUNQUOTA_ENDPOINT_SCOPE", "private")
    var connection = connectEndpoint(endpointForPath(socketPath))
    try:
      connection.sendFrame(encodeFrame(rqHello, FrameFlagRequest, 1'u64,
        encodeHello(HelloMessage(clientName: "rqns-probe",
          clientVersion: "0.0.0", minProtocolMajor: RqspProtocolMajor,
          maxProtocolMajor: RqspProtocolMajor, processId: processId,
          userId: userId, desiredCapabilities: capabilities))))
      var frame: RqspFrame
      var frameDiagnostic = okDiagnostic()
      check connection.receiveFrame(frame, frameDiagnostic, 5000)
      if frame.header.messageKind == rqError:
        var error: ProtocolErrorMessage
        check decodeProtocolError(frame.payload, error)
        return (frame.header.messageKind, error.diagnostic)
      (frame.header.messageKind, okDiagnostic())
    finally:
      connection.close()

  let root = scratchDir("rqns")
  let socket = root / "d.sock"
  let env = privateEnv(socket)
  let daemon = launch(root, socket, env, ["--cpu-milli", $BudgetMilli])

  # The daemon is stopped and its directory removed however the suite ends,
  # a crash or a failed prerequisite included.
  try:
    suite "foreign_namespace_client":
      prerequisite awaitSocket(daemon, socket),
        daemon.startupContext("the daemon did not bind " & socket)
      prerequisite unshareExe.len > 0, "no unshare on PATH"
      block probe:
        let p = startProcess(unshareExe, args = nsArgs(@["true"]),
                             options = {poStdErrToStdOut})
        let output = p.outputStream.readAll()
        let code = p.waitForExit()
        p.close()
        prerequisite code == 0,
          "unprivileged user and pid namespaces are not available: " & output

      test "a client in its own user and pid namespace is served as its host uid":
        let pidFile = root / "inner.pid"
        var clientEnv = newStringTable(modeCaseSensitive)
        for k, v in env: clientEnv[k] = v
        clientEnv["RUNQUOTA_SESSION"] = "rqns-session"
        let p = startProcess(unshareExe, env = clientEnv, args = nsArgs(@[
          cliPath(), "run", "--verbose", "--width", "1", "--", "/bin/sh", "-c",
          "echo $$ > '" & pidFile & "'; sleep 3"]),
          options = {poStdErrToStdOut})
        defer:
          if p.running:
            p.kill()
            discard p.waitForExit()
          p.close()
        let lease = waitRunningLease(env, 15_000)
        prerequisite lease.kind == JObject, "no lease of this client reached running"
        let host = namespaceInit(p.processID)
        check host > 0
        # The group the client named, owned by the uid the KERNEL names: this
        # test's uid, which is root inside the namespace.
        let (_, statusText) = cli(env, ["status", "--json"])
        let groups = parseJson(statusText)["session_groups"]
        var owner = -1
        for g in groups:
          if g["name"].getStr == "rqns-session": owner = g["owner_uid"].getInt
        check owner == int(getuid())
        # The child is watched through the peer -- the supervisor, pid 1 of the
        # namespace, by its host pid -- never by the pid it reported.
        check lease["foreign_pid_namespace"].getBool
        check lease["child_process_id"].getInt == host
        let output = p.outputStream.readAll()
        check p.waitForExit() == 0
        checkpoint(output)
        check "lease " in output
        check "no daemon reached" notin output
        let inner = parseInt(readFile(pidFile).strip())
        check inner != host
        check inner < 100   # the namespace's own numbering, not a host pid

      test "a lost supervisor in another pid namespace does not pin its lease":
        let p = startProcess(unshareExe, env = env, args = nsArgs(@[
          cliPath(), "run", "--width", "1", "--", "/bin/sh", "-c", "sleep 60"]),
          options = {poStdErrToStdOut})
        defer:
          if p.running:
            p.kill()
            discard p.waitForExit()
          p.close()
        let lease = waitRunningLease(env, 15_000)
        prerequisite lease.kind == JObject, "no lease of this client reached running"
        let host = namespaceInit(p.processID)
        prerequisite host > 0, "the namespace init was not found"
        # Kill the namespace's init (the supervisor) by the pid recorded above:
        # the kernel then ends every process in that pid namespace.
        check kill(Pid(host), SIGKILL) == 0
        discard p.waitForExit()
        # A request for the whole budget is admitted only once the lost lease
        # is released. Watched by its foreign pid (pid 2: the host's kthreadd)
        # it never would be, and this would wait out its bound.
        # `true` as this host has it: there is no `/bin/true` on NixOS.
        let wide = startProcess(cliPath(), env = env, args = ["run",
          "--verbose", "--width", "2", "--", trueCommand()],
          options = {poStdErrToStdOut})
        defer: wide.close()
        # On POSIX `waitForExit` kills a process still running at the end of
        # its bound, so a request still waiting after 20 s reads as exit 137.
        let code = wide.waitForExit(20_000)
        let text = wide.outputStream.readAll()
        checkpoint(text)
        check code == 0
        check "lease " in text
        for remaining in leasesJson(env):
          check remaining["id"].getInt != lease["id"].getInt
      test "a host client cannot claim another namespace to skip a check":
        # The lie a host client could tell: other namespaces, to be excused
        # from the declared-uid refusal or to have its connection watched in
        # its child's place. It is its own peer, in the daemon's namespaces,
        # so the kernel contradicts it and the Hello is refused.
        let own = currentNamespaces()
        prerequisite own.pidNamespace != 0'u64 and own.userNamespace != 0'u64,
          "this host does not expose /proc/self/ns"
        let pid = uint64(getCurrentProcessId())
        let fakePid = "pidns=" & $(own.pidNamespace + 1)
        let fakeUser = "userns=" & $(own.userNamespace + 1)
        # Another user namespace, declaring root: refused.
        let userLie = exchangeHello(socket, pid, 0'u64,
                                    "m1-lease " & fakeUser)
        check userLie.kind == rqError
        check userLie.diagnostic.code == diagDenied
        check "user namespace" in userLie.diagnostic.message
        # Another pid namespace, declaring its true uid: refused too.
        let pidLie = exchangeHello(socket, pid, uint64(getuid()),
                                   "m1-lease " & fakePid)
        check pidLie.kind == rqError
        check pidLie.diagnostic.code == diagDenied
        check "pid namespace" in pidLie.diagnostic.message
        # Both at once, and tokens naming its REAL namespaces: refused, and
        # served exactly as an old client is.
        check exchangeHello(socket, pid, 0'u64,
          "m1-lease " & fakePid & " " & fakeUser).kind == rqError
        check exchangeHello(socket, pid, uint64(getuid()), "m1-lease " &
          withNamespaceTokens("", own)).kind == rqHelloOk
        check exchangeHello(socket, pid, uint64(getuid()), "m1-lease").kind ==
          rqHelloOk
        # And the uid check it wanted to skip is still applied to it.
        check exchangeHello(socket, pid, 0'u64, "m1-lease").kind == rqError

  finally:
    daemon.stopOwned()
    removeDir(root)
