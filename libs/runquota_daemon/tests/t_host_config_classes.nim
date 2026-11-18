## The host budget file's class keys: `[reservation.<class>]` tables and
## `[admission] oversubscription`. What the reader accepts and refuses, what
## `runquota config set` writes for them, and that a file whose reservations
## do not fit the budget in force is refused at start and on reload.
##
## The decisions pinned here (the host file's class keys, as
## `docs/book-isonim/content/usage_guide/daemon.md` describes them for
## operators):
##
## * a reservation table is `[reservation.<class>]` with `cpu-milli`,
##   `memory-bytes` (integers) and `lend` (a bare TOML boolean, default
##   true); a class name is letters, digits, `_` and `-`, at most 64 bytes;
## * `oversubscription` is a quoted fraction from "0" to "1" with at most
##   three decimals; "10" (a percentage written where a fraction belongs) is
##   refused;
## * absent, there is no reservation and the target is 0;
## * the reservations together must fit the budget (not the oversubscribed
##   limit): otherwise the file is refused like one that does not parse, and
##   a reload changes nothing.
##
## NO MOCKS: the real reader and writer over real files in a scratch
## directory, and a real `RunQuotaDaemon` object for the reload.
##
## Each case names the change that makes it fail.

import std/[options, os, strutils, tables, unittest]

import runquota_core
import runquota_daemon {.all.}
import runquota_daemon/host_config

const GiB = 1024'u64 * 1024'u64 * 1024'u64

const Head = "schema = \"runquota.host-config.v1\"\n"

var scratchRoots: seq[string] = @[]

proc scratch(tag: string): string =
  result = getTempDir() / ("runquota-class-config-" & tag & "-" &
    $getCurrentProcessId())
  removeDir(result)
  createDir(result)
  scratchRoots.add(result)

proc parsed(text: string): HostConfig =
  parseHostConfig(Head & text, "test.toml")

proc refusal(text: string): string =
  try:
    discard parsed(text)
    ""
  except HostConfigError as err:
    err.msg

proc testDaemon(root: string): RunQuotaDaemon =
  var config = DaemonConfig(
    daemonId: 1'u64,
    cpuSlots: milliCpu(4000),
    memoryBytes: bytes(8'u64 * GiB),
    builtinCpuSlots: milliCpu(4000),
    builtinMemoryBytes: bytes(8'u64 * GiB),
    ioSlots: 8'u32,
    machines: initTable[string, MachineCapacity](),
    cpuShareGroups: initTable[string, CpuShareGroup](),
    namedPoolCaps: initTable[string, uint32](),
    version: "test",
    pressureSource: pressureSourceUnavailable,
    estimateDbPath: root / "estimates.db",
    estimateQueueCapacity: 8,
    observationDbPath: root / "observations.db",
    hostConfigPath: root / "runquotad.toml")
  let host = readHostConfig(config.hostConfigPath)
  config.resolveBudget(host)
  initDaemon(config)

suite "reading the class keys":
  test "a reservation table and the target, read":
    let host = parsed("[admission]\noversubscription = \"0.125\"\n" &
      "[reservation.ci]\ncpu-milli = 4_000\nmemory-bytes = 8589934592\n" &
      "lend = false\n" &
      "[reservation.vm-pool_2]\ncpu-milli = 1000\n")
    check host.oversubscriptionPermille == some(125'u32)
    check host.reservations.len == 2
    check host.reservations["ci"].cpuMilli == 4000'u64
    check host.reservations["ci"].memoryBytes == 8'u64 * GiB
    check not host.reservations["ci"].lend
    # `lend` defaults to true; an absent dimension reserves nothing.
    check host.reservations["vm-pool_2"].lend
    check host.reservations["vm-pool_2"].memoryBytes == 0'u64

  test "absent, nothing is reserved and the target is none":
    # Mutation: a default target or a default reservation would change
    # admission on every host that never wrote one.
    let host = parsed("[machine]\ncpu_milli = 4000\n")
    check host.oversubscriptionPermille.isNone
    check host.reservations.len == 0
    var daemon = testDaemon(scratch("absent"))
    check daemon.config.oversubscriptionPermille == 0'u32
    check daemon.config.reservations.len == 0

  test "fractions":
    var permille = 0'u32
    for (text, want) in [("0", 0'u32), ("0.1", 100'u32), ("0.125", 125'u32),
                         ("1", 1000'u32), ("1.0", 1000'u32), ("0.05", 50'u32)]:
      check parseOversubscriptionPermille(text, permille)
      check permille == want
    for bad in ["", "10", "1.5", "-0.1", "0.1234", "10%", ".5", "1.", "0,1",
                "1e-1", "nan"]:
      check not parseOversubscriptionPermille(bad, permille)
    check oversubscriptionText(0) == "0"
    check oversubscriptionText(100) == "0.1"
    check oversubscriptionText(125) == "0.125"
    check oversubscriptionText(1000) == "1"

  test "everything outside the subset is refused with its line":
    # Mutation: accepting any of these would start a daemon on a
    # reservation nobody wrote.
    for (text, needle) in [
        ("[admission]\noversubscription = \"10\"\n",
          "test.toml:3: oversubscription must be a fraction"),
        ("[admission]\noversubscription = 0.1\n", "double-quoted"),
        ("[reservation.ci.x]\n", "may hold only letters"),
        ("[reservation.]\n", "unknown table"),
        ("[reservation.c i]\n", "may hold only letters"),
        ("[reservation." & repeat('a', 65) & "]\n", "longer than 64"),
        ("[reservation.ci]\n[reservation.ci]\n", "appears twice"),
        ("[reservation.ci]\ncpu = 1000\n", "unknown key `cpu`"),
        ("[reservation.ci]\ncpu-milli = -1\n", "non-negative integer"),
        ("[reservation.ci]\nlend = \"true\"\n", "lend must be true or false"),
        ("[reservation.ci]\nlend = yes\n", "lend must be true or false")]:
      let message = refusal(text)
      check needle in message
      if needle notin message:
        echo "  for ", text.escape, ": ", message

  test "the file's class rule is the client's":
    # The reader states the rule itself (it imports only the standard
    # library); a name one side accepts and the other refuses would be a
    # class that can be named and never reserved for, or the reverse.
    for name in ["ci", "CI_2", "vm-pool", repeat('a', 64), "", "c i", "c.i",
                 "ci/x", "é", repeat('a', 65), "a\x01"]:
      check (reservationClassProblem(name) == "") ==
        (classNameProblem(name) == "")

suite "runquota config set":
  test "the class keys are written as the reader reads them":
    let root = scratch("set")
    let path = root / "runquotad.toml"
    var changed = false
    var text = editHostConfig(path, "reservation.ci.cpu-milli", "4000",
      unset = false, changed)
    writeFile(path, text)
    text = editHostConfig(path, "reservation.ci.memory-bytes", "8GiB",
      unset = false, changed)
    writeFile(path, text)
    text = editHostConfig(path, "reservation.ci.lend", "false",
      unset = false, changed)
    writeFile(path, text)
    text = editHostConfig(path, "admission.oversubscription", "0.1",
      unset = false, changed)
    writeFile(path, text)
    check "[reservation.ci]\ncpu-milli = 4000\nmemory-bytes = 8589934592" in
      text
    check "lend = false" in text
    check "oversubscription = \"0.1\"" in text
    let host = readHostConfig(path)
    check host.reservations["ci"].cpuMilli == 4000'u64
    check host.reservations["ci"].memoryBytes == 8'u64 * GiB
    check not host.reservations["ci"].lend
    check host.oversubscriptionPermille == some(100'u32)
    # Unset takes the key back to its default.
    text = editHostConfig(path, "reservation.ci.lend", "", unset = true,
      changed)
    writeFile(path, text)
    check readHostConfig(path).reservations["ci"].lend

  test "bad keys and values are refused before anything is written":
    let root = scratch("refuse")
    let path = root / "runquotad.toml"
    var changed = false
    for (key, value, needle) in [
        ("reservation.ci.cpu", "1", "has cpu-milli, memory-bytes, lend"),
        ("reservation.ci", "1", "a reservation is set as"),
        ("reservation.c.i.cpu-milli", "1", "may hold only"),
        ("reservation.ci.lend", "yes", "takes true or false"),
        ("reservation.ci.cpu-milli", "four", "non-negative integer"),
        ("admission.oversubscription", "10", "oversubscription must be"),
        ("admission.oversubscription", "\"0.1\"", "without quotes")]:
      try:
        discard editHostConfig(path, key, value, unset = false, changed)
        checkpoint key & " " & value & " was accepted"
        fail()
      except HostConfigError as err:
        check needle in err.msg
        if needle notin err.msg:
          echo "  for ", key, " ", value, ": ", err.msg
    check not fileExists(path)

suite "reservations against the budget":
  test "a file whose reservations exceed the budget does not start":
    # Mutation: dropping the check in `resolveBudget` starts a daemon that
    # has promised more than it has.
    let root = scratch("start")
    writeFile(root / "runquotad.toml", Head & "[machine]\ncpu_milli = 4000\n" &
      "[reservation.ci]\ncpu-milli = 3000\n[reservation.gpu]\n" &
      "cpu-milli = 2000\n")
    expect HostConfigError:
      discard testDaemon(root)

  test "the oversubscription target does not make room for reservations":
    let root = scratch("target")
    writeFile(root / "runquotad.toml", Head & "[machine]\ncpu_milli = 4000\n" &
      "[admission]\noversubscription = \"0.5\"\n[reservation.ci]\n" &
      "cpu-milli = 5000\n")
    expect HostConfigError:
      discard testDaemon(root)

  test "a reload that does not fit changes nothing":
    # Mutation: assigning the new configuration before checking it leaves
    # the refused reservations in force.
    let root = scratch("reload")
    let path = root / "runquotad.toml"
    writeFile(path, Head & "[reservation.ci]\ncpu-milli = 2000\n" &
      "memory-bytes = 1073741824\n[admission]\noversubscription = \"0.1\"\n")
    var daemon = testDaemon(root)
    check daemon.config.reservations["ci"].cpuMilli == 2000'u64
    check daemon.config.oversubscriptionPermille == 100'u32
    writeFile(path, Head & "[reservation.ci]\ncpu-milli = 9000\n")
    expect HostConfigError:
      discard daemon.reloadHostConfig()
    check daemon.config.reservations["ci"].cpuMilli == 2000'u64
    check daemon.config.oversubscriptionPermille == 100'u32
    # A good file is put in force whole: the dropped key goes back to its
    # default.
    writeFile(path, Head & "[reservation.ci]\ncpu-milli = 1000\n")
    discard daemon.reloadHostConfig()
    check daemon.config.reservations["ci"].cpuMilli == 1000'u64
    check daemon.config.reservations["ci"].memoryBytes == 0'u64
    check daemon.config.oversubscriptionPermille == 0'u32

for root in scratchRoots:
  removeDir(root)
