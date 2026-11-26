## The Nix modules can say everything the host budget file can say.
##
## `services.runquotad.hostConfig` (NixOS, nix-darwin) renders
## `/etc/runquota/runquotad.toml` as a link into the store, and
## `runquota config set` refuses a link. On such a host the module is the
## only writer, so a key it cannot render cannot be set there at all. It used
## to render `[machine] memory_bytes`, `cpu_milli` and `[pools]` and nothing
## else, while the reader had grown `[admission]`, `[benchmark]`,
## `[enforcement]`, `[reservation.<class>]` and `write_bytes_per_sec`
## (reprobuild-pm
## `issues/2026-11-18-runquota-nix-module-host-config-renders-only-machine-and-pools.md`).
##
## The property is held in two halves that meet in one file,
## `nix/tests/host-config-full.toml`:
##
## * `checks.module-eval` in `flake.nix` (and
##   `nix/tests/render-host-config.nix` without the flake) refuses a module
##   whose rendering of `nix/tests/host-config-full.nix` differs from that
##   file by a byte;
## * this test holds that file to `parseHostConfig`, the daemon's own reader:
##   it is accepted, and it SETS EVERY FIELD OF `HostConfig`. The fields are
##   walked with `fieldPairs`, so a key added to the reader fails here until
##   the file sets it, and the file cannot set it until the module renders
##   it.
##
## `nix/host-config.nix` also repeats what the reader accepts for a key: the
## admission order keys, the `share-between-users` values, the pressure
## defaults, the class-name length and the oversubscription maximum. Nix
## cannot import them from Nim, so the last case pins the reader's side: a
## change there fails here and names the Nix line to change with it.
##
## NO MOCKS: the real reader over the committed file.
##
## Each case names the change that makes it fail.

import std/[options, os, strutils, tables, unittest]

import runquota_daemon/cpu_pressure
import runquota_daemon/host_config

const
  RepoRoot = currentSourcePath().parentDir.parentDir.parentDir.parentDir
  FullPath = RepoRoot / "nix" / "tests" / "host-config-full.toml"

proc unsetProblem[T](name: string; value: Option[T]): string =
  if value.isNone: name & " is not set" else: ""

proc unsetProblem(name: string; value: seq[string]): string =
  if value.len == 0: name & " is empty" else: ""

proc unsetProblem[K, V](name: string; value: OrderedTable[K, V]): string =
  if value.len == 0: name & " is empty" else: ""

suite "the Nix modules' host budget file covers the daemon's reader":
  let text = readFile(FullPath)
  let cfg = parseHostConfig(text, FullPath)

  test "every field of HostConfig is set by the file the module renders":
    # Fails when a key is added to the reader (a field of `HostConfig`) and
    # `nix/tests/host-config-full.toml` does not set it, i.e. when
    # `nix/host-config.nix` has no option that renders it.
    var missing: seq[string] = @[]
    for name, value in fieldPairs(cfg):
      when name == "sourcePath":
        discard
      else:
        let problem = unsetProblem(name, value)
        if problem.len > 0:
          missing.add(problem)
    check missing == newSeq[string]()

  test "every key of a reservation table is set away from its default":
    # Fails when a key is added to `[reservation.<class>]` and the module
    # does not render it, or when the module stops rendering one of these.
    # The Windows keys (`allowed-users`, `allowed-groups`) are refused in a
    # file read for Linux or macOS, the only hosts the modules configure, so
    # the modules do not render them; every POSIX key is rendered.
    check ReservationKeys == ["cpu-milli", "memory-bytes", "lend",
      "socket-owner", "socket-group", "socket-mode", "allowed-users",
      "allowed-groups"]
    check PosixClassSocketKeys == ["socket-owner", "socket-group",
      "socket-mode"]
    check cfg.reservations.hasKey("ci")
    let ci = cfg.reservations.getOrDefault("ci")
    check ci.cpuMilli == 8000'u64
    check ci.memoryBytes == 34359738368'u64
    check ci.lend == false
    check ci.socketOwner == "1001"
    check ci.socketOwnerUid == 1001
    check ci.socketGroup == "2000"
    check ci.socketGroupGid == 2000
    check ci.socketMode == 0o660

  test "a class declared without a key reserves nothing and lends":
    # Fails when the module stops writing the header of a class that sets no
    # key, or writes a key for an option left unset.
    check cfg.reservations.hasKey("interactive")
    let interactive = cfg.reservations.getOrDefault("interactive")
    check interactive.cpuMilli == 0'u64
    check interactive.memoryBytes == 0'u64
    check interactive.lend == true
    check interactive.socketMode == DefaultClassSocketMode
    check interactive.socketOwnerUid == -1
    check interactive.socketGroupGid == -1

  test "the values arrive as the module's options spell them":
    # Fails when the module renders a key under another name, in another
    # table, or with a value the reader reads differently.
    check cfg.memoryBytes == some(103079215104'u64)
    check cfg.cpuMilli == some(16000'u64)
    check cfg.writeBytesPerSec == some(524288000'u64)
    check cfg.pools.getOrDefault("compile") == 8'u32
    check cfg.pools.getOrDefault("fetch") == 2'u32
    check cfg.admissionOrder == some(@["starvation", "fair-share", "arrival"])
    check cfg.admissionMaxWaitMillis == some(90_000'i64)
    check cfg.shareBetweenUsers == some("none")
    check cfg.admissionPredictive == some(true)
    check cfg.admissionHorizonMillis == some(10_000'i64)
    check cfg.pressureHighPct == some(12.5)
    check cfg.pressureLowPct == some(4.0)
    check cfg.oversubscriptionPermille == some(125'u32)
    check cfg.benchmarkAllowedUsers == @["alice", "1001"]
    check cfg.benchmarkAllowedGroups == @["bench"]
    check cfg.benchmarkMaxQueueWaitMillis == some(5'i64 * 60_000'i64)
    check cfg.benchmarkMaxHoldMillis == some(30'i64 * 60_000'i64)
    check cfg.enforcementCgroups == some(true)
    check cfg.enforcementJobPriority == some(false)
    check cfg.enforcementQos == some(true)

  test "the file names every table the reader knows":
    # Fails when the reader gains a table and its refusal of an unknown one
    # is updated, but the module's file has no such header.
    var refusal = ""
    try:
      discard parseHostConfig("[no-such-table]\n", "probe")
    except HostConfigError as err:
      refusal = err.msg
    let expected = refusal[refusal.find("expected ") + "expected ".len ..
      refusal.find(" (runquota host configuration") - 1]
    var tables: seq[string] = @[]
    for part in expected.replace(" or ", ", ").split(", "):
      tables.add(part.strip())
    check tables.len >= 6
    for header in tables:
      if header == "[reservation.<class>]":
        check "\n[reservation.ci]\n" in text
      else:
        check ("\n" & header & "\n") in text

  test "the values nix/host-config.nix repeats are the reader's":
    # Fails when the reader accepts a new value for a key, or moves a default
    # or a bound, and `nix/host-config.nix` still carries the old one: its
    # `admissionOrderKeys`, the `shareBetweenUsers` enum, `defaultPressureHigh`
    # / `defaultPressureLow`, `isClassName` and the `fraction` type. Change
    # them together with this case.
    check AdmissionOrderKeys == ["starvation", "priority", "cache-deadline",
      "fair-share", "arrival"]
    check ShareBetweenUsersValues == ["drf", "none"]
    check DefaultPressureHighPct == 10.0
    check DefaultPressureLowPct == 5.0
    check MaxOversubscriptionPermille == 1000'u32
    check reservationClassProblem(repeat('a', 64)) == ""
    check reservationClassProblem(repeat('a', 65)) != ""
    check reservationClassProblem("a.b") != ""
    # `classSocketModes` of nix/host-config.nix.
    check ClassSocketModes == ["0600", "0660", "0666"]
