## Class sockets on the wire: what `ClassSocketsMinor` changes, and what it
## does not.
##
## RAN ON: Linux (x86_64). The codec cases are platform-neutral; the
## cross-runs need the binaries of a daemon and CLI from before class sockets
## (protocol minor 12), named by `RUNQUOTA_COMPAT_MINOR12_BIN` (a directory
## holding `runquotad` and `runquota`), and report themselves skipped
## without it.
##
## THE COMPATIBILITY FACTS:
##
## * no existing message changed: a `HelloOk` on the shared socket (no
##   class) is byte-identical to what a minor-12 daemon sends, so a minor-12
##   client still decodes it; only a class socket's `HelloOk` carries the
##   trailing class, and a minor-12 client never connects to one. Written
##   field by field here, not through the current encoder, so the case
##   cannot pass by the encoder agreeing with itself;
## * the `RegisterSession` class block is the minor-12 block, unchanged;
## * cross-run: a new client against a minor-12 daemon (no class sockets)
##   sends the class block as at minor 12 and is served in its class; a
##   minor-12 client against the new daemon is refused on the shared socket
##   when it names a class (naming the class socket) and served when it does
##   not.
##
## NO MOCKS: the real codec over real bytes, and for the cross-runs real
## daemons on private sockets in scratch directories.

import std/[os, strutils, unittest]

import runquota_codec
import runquota_core
import runquota_protocol

proc minor12HelloOk(msg: HelloOkMessage): string =
  ## A minor-12 daemon's `HelloOk`, field by field.
  var w = writer()
  w.writeU16(msg.selectedProtocolMajor)
  w.writeU16(msg.selectedProtocolMinor)
  w.writeU64(msg.daemonId)
  w.writeString(msg.daemonVersion)
  w.writeCapabilities(msg.capabilities)
  w.writeU32(msg.flow.maxInflightRequests)
  w.writeU32(msg.flow.maxFrameBytes)
  w.writeU32(msg.flow.maxCandidatesPerBatch)
  w.writeU32(msg.flow.maxLeaseDecisionsPerBatch)
  w.data

proc sample(className = ""): HelloOkMessage =
  HelloOkMessage(selectedProtocolMajor: RqspProtocolMajor,
    selectedProtocolMinor: ClassSocketsMinor, daemonId: 7'u64,
    daemonVersion: "0.test",
    capabilities: defaultCapabilities("linux", "unix-socket", milliCpu(4000),
      bytes(1'u64 shl 30)),
    flow: defaultFlowControlLimits(), connectionClass: className)

suite "class_socket_codec":
  test "the minor number":
    check ClassSocketsMinor == 13'u16
    check ClassSocketsMinor > ClassesMinor
    when ClassSocketsServed:
      check RqspProtocolMinor == ClassSocketsMinor
    else:
      # A platform whose daemon does not serve class sockets yet keeps the
      # minor-12 behaviour and says so.
      check RqspProtocolMinor == ClassesMinor

  test "the shared socket's HelloOk is the minor-12 bytes":
    check encodeHelloOk(sample()) == minor12HelloOk(sample())
    var decoded: HelloOkMessage
    check decodeHelloOk(minor12HelloOk(sample()), decoded)
    check decoded.connectionClass == ""

  test "a class socket's HelloOk names the class after the minor-12 fields":
    let bytes = encodeHelloOk(sample("ci"))
    check bytes.startsWith(minor12HelloOk(sample()))
    var decoded: HelloOkMessage
    check decodeHelloOk(bytes, decoded)
    check decoded.connectionClass == "ci"
    check decoded.daemonId == 7'u64
    # A class outside the class-name rule, or bytes after the class, is a
    # malformed frame.
    var bad = writer()
    bad.writeString("not a class")
    check not decodeHelloOk(minor12HelloOk(sample()) & bad.data, decoded)
    check not decodeHelloOk(bytes & "\x00", decoded)

  test "the RegisterSession class block is unchanged":
    # The block a minor-12 client writes for class `ci` and nothing else:
    # an empty group block and an empty sizing block before it.
    var w = writer()
    w.writeString("s")
    w.writeString("1")
    w.writeMetadata(metadataNone())
    w.writeString("")
    w.writeBool(false)
    w.writeU32(uint32(ord(sessionPriorityNormal)))
    w.writeBool(false)
    w.writeU64(0'u64)
    w.writeString("")
    w.writeString("")
    w.writeString("ci")
    check encodeRegisterSession(RegisterSessionMessage(name: "s",
      version: "1", metadata: metadataNone(),
      group: SessionGroupDeclaration(priority: sessionPriorityNormal,
        className: "ci"))) == w.data

when defined(posix):
  import std/[osproc, streams, strtabs]

  import daemon_binary
  import private_daemon_fixture

  const Head = "schema = \"runquota.host-config.v1\"\n"

  proc minor12Bin(): string = getEnv("RUNQUOTA_COMPAT_MINOR12_BIN")

  proc startWith(daemon, root, socket: string; env: StringTableRef):
      Process =
    result = startProcess(daemon, env = env,
      args = daemonArgs(root, socket, @["--cpu-milli", "4000"]),
      options = {poStdErrToStdOut})
    let deadline = 300
    for i in 0 ..< deadline:
      if isSocket(socket) or not result.running:
        break
      sleep(100)

  proc reportClass(cli: string; env: StringTableRef; className: string):
      tuple[code: int, output: string] =
    ## `runquota pressure report --class C` (a session that claims C),
    ## ended at once by closing its input.
    let process = startProcess(cli, env = env,
      args = ["pressure", "report", "--class", className],
      options = {poStdErrToStdOut})
    process.inputStream.close()
    let output = process.outputStream.readAll()
    (code: process.waitForExit(), output: output)

  suite "class_socket_cross_runs":
    test "a new client against a minor-12 daemon sends the class block":
      if minor12Bin().len == 0:
        echo "SKIPPED: RUNQUOTA_COMPAT_MINOR12_BIN names no minor-12 build"
        skip()
      else:
        let root = scratchDir("clscompat-old-daemon")
        defer: removeDir(root)
        let socket = root / "rq.sock"
        let env = privateEnv(socket)
        writeFile(root / "host.toml", Head & "[reservation.ci]\n")
        let daemon = startWith(minor12Bin() / "runquotad", root, socket, env)
        defer: stopOwned(daemon)
        check isSocket(socket)
        # The old daemon has no class socket, so the new client asks the
        # shared one, and the old daemon serves the class there.
        check not isSocket(root / "class-ci.sock")
        let (code, output) = reportClass(cliPath(), env, "ci")
        checkpoint output
        check code == 0
        check output.startsWith("ready ")

    test "a minor-12 client against the new daemon":
      if minor12Bin().len == 0:
        echo "SKIPPED: RUNQUOTA_COMPAT_MINOR12_BIN names no minor-12 build"
        skip()
      else:
        let root = scratchDir("clscompat-new-daemon")
        defer: removeDir(root)
        let socket = root / "rq.sock"
        let env = privateEnv(socket)
        writeFile(root / "host.toml", Head & "[reservation.ci]\n")
        let daemon = startWith(daemonPath(), root, socket, env)
        defer: stopOwned(daemon)
        check isSocket(root / "class-ci.sock")
        # Naming a class on the shared socket: refused, naming the socket.
        let (code, output) = reportClass(minor12Bin() / "runquota", env, "ci")
        checkpoint output
        check code != 0
        check (root / "class-ci.sock") in output
        # Naming none: served as before -- a session, a lease, a release.
        let plain = startProcess(minor12Bin() / "runquota", env = env,
          args = ["acquire"], options = {poStdErrToStdOut})
        let plainOutput = plain.outputStream.readAll()
        let plainCode = plain.waitForExit()
        plain.close()
        checkpoint plainOutput
        check plainCode == 0
        let (statusCode, statusOutput) = cli(env, ["status", "--json"])
        check statusCode == 0
        check "\"total_granted\":1," in statusOutput
