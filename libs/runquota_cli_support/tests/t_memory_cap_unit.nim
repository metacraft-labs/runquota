## Trap 2 in `runquota status`: the systemd unit enclosing the cgroup root
## must keep `Delegate=yes` and must not set `OOMPolicy=stop` or `kill`, or
## one task's cap kill could stop the whole unit.
##
## WHAT IS GUARDED, each with the change that makes it fail:
##
## * The unit is the deepest `.service` / `.scope` strictly above the root,
##   with the user manager's units told apart from the system manager's.
##   Mutation: taking the first unit from the top (an explicit root under a
##   unit of the user's manager then names `user@<uid>.service`).
## * Unsafe when `Delegate` is not `yes`, when `OOMPolicy` is `stop` or
##   `kill`, and when either is unknown. Mutation: ignoring `OOMPolicy`
##   (the `Delegate=yes OOMPolicy=stop` case then reads as safe).
## * Every unit above the root is checked, deepest first, up to and
##   including `user@<uid>.service`: any one with a bad policy can be
##   stopped by a cap kill below it. Mutation: the nearest unit only.
## * A `systemctl` that does not answer is killed at the timeout (a
##   stand-in program in its place, the one non-real part, because a hung
##   bus cannot be arranged). Mutation: waiting without a timeout.
## * On this host, the real `systemctl show` of the unit enclosing the
##   default root answers (when there is a systemd user manager to ask).
##
## NO MOCKS: the pure rules take `systemctl show` text; the host case runs
## the real `systemctl`.
import std/[os, posix, strutils, times, unittest]
import runquota_cli_support/memory_cap_unit

const SlowSystemctlEnvVar = "RUNQUOTA_TEST_SLOW_SYSTEMCTL"
  ## Set only in the child `queryUnitPolicy` launches below, on Windows,
  ## where there is no shebang script to stand in for a hung `systemctl`
  ## (`startProcess` there has no shell to interpret one, and a bare
  ## extensionless file is "not a valid Win32 application"). This test
  ## binary, re-invoked, sleeps past the timeout in its place.

if getEnv(SlowSystemctlEnvVar).len > 0:
  sleep(30_000)
  quit(0)

suite "the unit enclosing the cgroup root":
  test "the deepest service or scope above the root":
    let default = enclosingUnit(
      "/sys/fs/cgroup/user.slice/user-1000.slice/user@1000.service/runquota.slice")
    check default.name == "user@1000.service"
    check not default.userManager
    let explicit = enclosingUnit("/sys/fs/cgroup/user.slice/user-1000.slice/" &
      "user@1000.service/app.slice/build.service/rq")
    check explicit.name == "build.service"
    check explicit.userManager
    let scope = enclosingUnit("/sys/fs/cgroup/user.slice/user-1000.slice/" &
      "user@1000.service/app.slice/x.scope/rq.slice")
    check scope.name == "x.scope"
    # The root itself is never its own enclosing unit.
    check enclosingUnit("/sys/fs/cgroup/system.slice/a.service").name == ""
    check enclosingUnit("/sys/fs/cgroup/a.slice/b.slice").name == ""
    check enclosingUnit("").name == ""

  test "every unit above the root, deepest first, up to the user manager":
    let units = enclosingUnits("/sys/fs/cgroup/user.slice/user-1000.slice/" &
      "user@1000.service/app.slice/build.service/inner.scope/rq")
    check units.len == 3
    check units[0].name == "inner.scope" and units[0].userManager
    check units[1].name == "build.service" and units[1].userManager
    check units[2].name == "user@1000.service" and not units[2].userManager
    check enclosingUnits("/sys/fs/cgroup/user.slice/user-1000.slice/" &
      "user@1000.service/runquota.slice").len == 1

  test "a systemctl that does not answer is stopped at the timeout":
    # A stand-in for a hung bus: a program in systemctl's place that does
    # not answer. The query must give up at its timeout, kill it, and say
    # so, rather than wait. Mutation: a wait without a real timeout.
    let dir = getTempDir() / ("rq-unit-" & $getpid())
    createDir(dir)
    defer: removeDir(dir)
    var slow: string
    when defined(windows):
      # No shebang script here: `startProcess` has no shell to run one
      # through, and an extensionless file is not a launchable program.
      # This test binary, re-invoked with the marker set, sleeps instead.
      slow = getAppFilename()
      putEnv(SlowSystemctlEnvVar, "1")
    else:
      slow = dir / "systemctl"
      # Absolute: systemctl runs with an environment that has no PATH.
      writeFile(slow, "#!/bin/sh\n" & findExe("sleep", followSymlinks = false) &
        " 30\n")
      setFilePermissions(slow, {fpUserRead, fpUserWrite, fpUserExec})
    defer:
      when defined(windows):
        delEnv(SlowSystemctlEnvVar)
    let started = epochTime()
    let policy = queryUnitPolicy(EnclosingUnit(name: "x.service"),
      timeoutMillis = 300, systemctl = slow)
    check not policy.known
    check "did not answer" in policy.problem
    check epochTime() - started < 5.0

  test "unsafe unless Delegate=yes and OOMPolicy is not stop or kill":
    check memoryCapUnsafeReason(parseUnitPolicy(
      "Delegate=yes\nOOMPolicy=continue\n")) == ""
    let stop = memoryCapUnsafeReason(parseUnitPolicy(
      "Delegate=yes\nOOMPolicy=stop\n"))
    check "OOMPolicy=stop" in stop
    check "OOMPolicy=kill" in memoryCapUnsafeReason(parseUnitPolicy(
      "OOMPolicy=kill\nDelegate=yes\n"))
    check "Delegate=no" in memoryCapUnsafeReason(parseUnitPolicy(
      "Delegate=no\nOOMPolicy=continue\n"))
    let unknown = parseUnitPolicy("Delegate=yes\n")
    check not unknown.known
    check memoryCapUnsafeReason(unknown).len > 0

  test "the status lines":
    let unit = EnclosingUnit(name: "user@1000.service")
    let safe = unitPolicyLines(unit, parseUnitPolicy(
      "Delegate=yes\nOOMPolicy=continue\n"))
    check safe == @["memory_cap_unit: user@1000.service delegate=yes " &
      "oom_policy=continue"]
    let unsafe = unitPolicyLines(unit, parseUnitPolicy(
      "Delegate=no\nOOMPolicy=stop\n"))
    check unsafe.len == 2
    check unsafe[1].startsWith("memory_cap_unsafe: ")
    check "user@1000.service" in unsafe[1]

  when defined(posix):
    test "this host's user manager answers":
      # `user@<uid>.service` is a systemd unit, which exists only on
      # Linux; `getuid()` itself has no Windows form (there is no uid
      # there, see runquota_core/owner_id.nim), unlike the runtime
      # "systemctl absent" case just below, which would run fine on any
      # POSIX host without one.
      let unit = EnclosingUnit(name: "user@" & $getuid() & ".service")
      let policy = queryUnitPolicy(unit)
      if not policy.known and findExe("systemctl").len == 0:
        echo "SKIPPED: " & policy.problem
        skip()
      elif not policy.known:
        # A container or CI host without a running user manager: say what
        # systemctl answered rather than fail on the host.
        echo "SKIPPED: " & policy.problem
        skip()
      else:
        check policy.delegate.len > 0
        check policy.oomPolicy.len > 0
        echo "  ", unitPolicyLines(unit, policy).join(" / ")
