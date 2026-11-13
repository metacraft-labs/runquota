## The `[admission]` table of the host budget file: what the reader accepts
## and refuses, how the file and the `--admission-max-wait-millis` flag
## combine, and what `runquota config set` writes for these keys.
##
## The decisions pinned here (reprobuild-specs Build-Engine-And-Scheduler.md,
## "Configuring the order", and RunQuota-Host-Configuration.md, "Shape"):
##
## * `order` must name only the five keys, none twice, at least one; anything
##   else makes the file not parse (the daemon does not start, a reload is
##   refused and changes nothing);
## * `max-wait` is a duration; the flag wins over the file, for the launch and
##   across reloads, and the reload answer names the key it pins;
## * an absent key is the default, so removing it under a running daemon puts
##   the default back.
##
## NO MOCKS. A real `RunQuotaDaemon` object reads a real TOML file in a
## scratch directory, as `t_host_config_reload` does; the end-to-end order
## through a real `runquotad` is `tests/integration/t_session_group_admission`.
##
## Each case names the change that makes it fail.

import std/[options, os, strutils, tables, unittest]

import runquota_admission
import runquota_core
import runquota_daemon {.all.}
import runquota_daemon/host_config

const GiB = 1024'u64 * 1024'u64 * 1024'u64

const Head = "schema = \"runquota.host-config.v1\"\n"

var scratchRoots: seq[string] = @[]

proc scratch(tag: string): string =
  result = getTempDir() / ("runquota-admission-config-" & tag & "-" &
    $getCurrentProcessId())
  removeDir(result)
  createDir(result)
  scratchRoots.add(result)

proc parsed(text: string): HostConfig =
  parseHostConfig(Head & text, "test.toml")

proc refusal(text: string): string =
  ## The reader's message for `text`, or "" when it accepted it.
  try:
    discard parsed(text)
    ""
  except HostConfigError as err:
    err.msg

proc testDaemon(root: string; flags = BudgetFlags()): RunQuotaDaemon =
  ## A daemon laid out the way `runquotad` lays one out: built-in defaults,
  ## then the file at `root/runquotad.toml`, then `flags`.
  var config = DaemonConfig(
    daemonId: 1'u64,
    cpuSlots: milliCpu(4000),
    memoryBytes: bytes(2'u64 * GiB),
    builtinCpuSlots: milliCpu(4000),
    builtinMemoryBytes: bytes(2'u64 * GiB),
    ioSlots: 8'u32,
    machines: initTable[string, MachineCapacity](),
    cpuShareGroups: initTable[string, CpuShareGroup](),
    namedPoolCaps: initTable[string, uint32](),
    version: "test",
    pressureSource: pressureSourceUnavailable,
    estimateDbPath: root / "estimates.db",
    estimateQueueCapacity: 8,
    observationDbPath: root / "observations.db",
    hostConfigPath: root / "runquotad.toml",
    budgetFlags: flags)
  let host = readHostConfig(config.hostConfigPath)
  config.resolveBudget(host)
  config.hostConfigSource = host.sourcePath
  initDaemon(config)

suite "the [admission] table":
  test "every key, read":
    let host = parsed("[admission]\n" &
      "order = [\"starvation\", \"fair-share\", \"arrival\"]  # equal shares\n" &
      "max-wait = \"90s\"\n" &
      "share-between-users = \"none\"\n")
    check host.admissionOrder == some(@["starvation", "fair-share", "arrival"])
    check host.admissionMaxWaitMillis == some(90_000'i64)
    check host.shareBetweenUsers == some("none")

  test "absent keys stay absent":
    let host = parsed("[admission]\n")
    check host.admissionOrder.isNone
    check host.admissionMaxWaitMillis.isNone
    check host.shareBetweenUsers.isNone

  test "durations":
    var millis = -1'i64
    check parseDurationMillis("1500ms", millis) and millis == 1500
    check parseDurationMillis("120s", millis) and millis == 120_000
    check parseDurationMillis("2m", millis) and millis == 120_000
    check parseDurationMillis("0s", millis) and millis == 0
    for bad in ["", "s", "120", "1.5s", "-1s", "12h", "1 s", "9999999999999999999s"]:
      check not parseDurationMillis(bad, millis)
    check parsed("[admission]\nmax-wait = \"0s\"\n").admissionMaxWaitMillis ==
      some(0'i64)

  test "an unknown, repeated or empty order is refused with its line":
    # Accepting any of these would start a daemon on an order nobody wrote.
    check "test.toml:3: unknown admission order key `fairness`" in
      refusal("[admission]\norder = [\"starvation\", \"fairness\"]\n")
    check "test.toml:3: admission order lists `arrival` twice" in
      refusal("[admission]\norder = [\"arrival\", \"priority\", \"arrival\"]\n")
    check "test.toml:3: admission order is empty" in
      refusal("[admission]\norder = []\n")

  test "everything else outside the subset is refused":
    for (text, needle) in [
        ("[admission]\norder = \"arrival\"\n", "one-line array"),
        ("[admission]\norder = [arrival]\n", "double-quoted"),
        ("[admission]\norder = [\"arr\\\"ival\"]\n", "unsupported string"),
        ("[admission]\norder = [\"starvation\",\n", "one-line array"),
        ("[admission]\nmax-wait = 120\n", "double-quoted"),
        ("[admission]\nmax-wait = \"two minutes\"\n", "max-wait must be"),
        ("[admission]\nshare-between-users = \"fair\"\n",
          "share-between-users must be drf or none"),
        ("[admission]\nshare-between-users = drf\n", "double-quoted"),
        ("[admission]\noversubscription = 0\n", "unknown key `oversubscription`"),
        ("[admissions]\n", "unknown table")]:
      let message = refusal(text)
      check needle in message
      if needle notin message:
        echo "  for ", text.escape, ": ", message

  test "the file's keys are the admission library's keys":
    # The reader keeps its own list (it is standard-library only); a key added
    # to one and not the other would be refused, or accepted and then
    # rejected by the daemon.
    var names: seq[string] = @[]
    for key in AdmissionKey:
      names.add($key)
    check names == @AdmissionOrderKeys
    var shares: seq[string] = @[]
    for share in ShareBetweenUsers:
      shares.add($share)
    check shares == @ShareBetweenUsersValues
    var keys: seq[AdmissionKey]
    var error = ""
    check parseAdmissionOrder(AdmissionOrderKeys, keys, error)

suite "the admission policy in force":
  test "no file: the defaults":
    let root = scratch("defaults")
    let daemon = testDaemon(root)
    check daemon.config.admissionOrder == @DefaultAdmissionOrder
    check daemon.config.admissionMaxWaitMillis == DefaultMaxWaitMillis
    check daemon.config.shareBetweenUsers == sbuDrf

  test "the file's keys are put in force, and a reload takes them back":
    # Ignoring the file's order (hard-coding the default) fails the first
    # three checks; keeping the last file's values after the keys are removed
    # fails the last three.
    let root = scratch("file")
    writeFile(root / "runquotad.toml", Head & "[admission]\n" &
      "order = [\"starvation\", \"fair-share\", \"arrival\"]\n" &
      "max-wait = \"45s\"\nshare-between-users = \"none\"\n")
    var daemon = testDaemon(root)
    check daemon.config.admissionOrder == @[akStarvation, akFairShare,
      akArrival]
    check daemon.config.admissionMaxWaitMillis == 45_000'i64
    check daemon.config.shareBetweenUsers == sbuNone
    writeFile(root / "runquotad.toml", Head)
    discard daemon.reloadHostConfig()
    check daemon.config.admissionOrder == @DefaultAdmissionOrder
    check daemon.config.admissionMaxWaitMillis == DefaultMaxWaitMillis
    check daemon.config.shareBetweenUsers == sbuDrf

  test "the max-wait flag wins over the file, across reloads":
    # Letting the file override the flag on reload makes the flag mean
    # "until someone edits the file".
    let root = scratch("flag")
    writeFile(root / "runquotad.toml", Head & "[admission]\n" &
      "max-wait = \"45s\"\n")
    var daemon = testDaemon(root,
      BudgetFlags(admissionMaxWaitMillis: some(1500'i64)))
    check daemon.config.admissionMaxWaitMillis == 1500'i64
    writeFile(root / "runquotad.toml", Head & "[admission]\n" &
      "max-wait = \"10s\"\n")
    let answer = daemon.reloadHostConfig()
    check daemon.config.admissionMaxWaitMillis == 1500'i64
    check "admission.max-wait" in answer.pinnedByFlags
    # Without the flag the file's value is in force, and nothing is pinned.
    var unpinned = testDaemon(root)
    check unpinned.config.admissionMaxWaitMillis == 10_000'i64
    check "admission.max-wait" notin unpinned.reloadHostConfig().pinnedByFlags

  test "a reload whose order does not parse changes nothing":
    let root = scratch("broken")
    writeFile(root / "runquotad.toml", Head & "[admission]\n" &
      "order = [\"fair-share\", \"arrival\"]\nmax-wait = \"30s\"\n")
    var daemon = testDaemon(root)
    writeFile(root / "runquotad.toml", Head & "[admission]\n" &
      "order = [\"fair-share\", \"fair-share\"]\nmax-wait = \"5s\"\n")
    expect HostConfigError:
      discard daemon.reloadHostConfig()
    check daemon.config.admissionOrder == @[akFairShare, akArrival]
    check daemon.config.admissionMaxWaitMillis == 30_000'i64
    check daemon.hostConfigReloads == 0'u64

suite "runquota config set for [admission]":
  test "values are written in the daemon's spelling and read back":
    let root = scratch("set")
    let path = root / "runquotad.toml"
    var changed = false
    var text = editHostConfig(path, "admission.order",
      "starvation, fair-share,arrival", unset = false, changed)
    check changed
    check "order = [\"starvation\", \"fair-share\", \"arrival\"]" in text
    writeFile(path, text)
    text = editHostConfig(path, "admission.max-wait", "90s", unset = false,
      changed)
    writeFile(path, text)
    text = editHostConfig(path, "admission.share-between-users", "none",
      unset = false, changed)
    writeFile(path, text)
    let host = readHostConfig(path)
    check host.admissionOrder == some(@["starvation", "fair-share", "arrival"])
    check host.admissionMaxWaitMillis == some(90_000'i64)
    check host.shareBetweenUsers == some("none")
    # The template's other lines survive the edits.
    check "# compile = 8" in text
    text = editHostConfig(path, "admission.order", "", unset = true, changed)
    check changed
    check "order =" notin text

  test "a value the reader would refuse is never written":
    let root = scratch("refuse")
    let path = root / "runquotad.toml"
    var changed = false
    for (key, value) in [("admission.order", "starvation,starvation"),
        ("admission.order", "fairshare"), ("admission.max-wait", "soon"),
        ("admission.share-between-users", "\"drf\""),
        ("admission.unknown", "1")]:
      expect HostConfigError:
        discard editHostConfig(path, key, value, unset = false, changed)
    check not fileExists(path)

for root in scratchRoots:
  removeDir(root)
