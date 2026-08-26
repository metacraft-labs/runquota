import std/[json, os, osproc, strutils, unittest]

when defined(posix):
  import std/posix

from runquota_ipc import endpointDirectoryPermissions
import runquota_client
import runquota_core
import runquota_core/child_process
import runquota_exec
import runquota_process
import daemon_binary

const FixtureOutput = "--m5-fixture-output"
const FixtureCwdEnv = "--m5-fixture-cwd-env"
const FixtureSleep = "--m5-fixture-sleep"
const FixtureExit7 = "--m5-fixture-exit7"
const FixtureEnvName = "RUNQUOTA_M5_CHILD_ENV"
const FixtureRecord = "runquota-m5-cwd-env.txt"
const FixtureEnvDump = "--m5-fixture-env-dump"
const FixtureArgv0 = "--m5-fixture-argv0"

if commandLineParams().len >= 1 and commandLineParams()[0] == FixtureEnvDump:
  # Report exactly the variables the caller asked about, reading the child's
  # environment block rather than asking `getEnv`. `getEnv` cannot answer
  # either question this fixture exists to answer: it returns "" both for a
  # variable that is absent and for one that is present but empty, and when a
  # name appears twice it reports only the first. The composed environment
  # must neither drop an entry nor carry two entries for the same name, so
  # both the absent/empty split and the occurrence count are printed.
  for name in commandLineParams()[1 .. ^1]:
    var occurrences = 0
    var firstValue = ""
    for key, value in envPairs():
      if key == name:
        if occurrences == 0:
          firstValue = value
        inc occurrences
    if occurrences == 0:
      stdout.write(name & "=<absent>\n")
    else:
      stdout.write(name & "=[" & firstValue & "]\n")
    stdout.write(name & " occurrences=" & $occurrences & "\n")
  quit 0

if commandLineParams().len == 1 and commandLineParams()[0] == FixtureArgv0:
  # `paramStr(0)` is `argv[0]` as the kernel received it, which is not the same
  # as `getAppFilename()`: the latter resolves the running image.
  stdout.write("argv0=[" & paramStr(0) & "]\n")
  quit 0

if commandLineParams().len == 1 and commandLineParams()[0] == FixtureOutput:
  stdout.write("m5 stdout\n")
  stderr.write("m5 stderr\n")
  quit 0

if commandLineParams().len == 1 and commandLineParams()[0] == FixtureCwdEnv:
  let cwd = getCurrentDir()
  let envValue = getEnv(FixtureEnvName)
  stdout.write("m5 cwd=" & cwd & "\n")
  stdout.write("m5 env=" & envValue & "\n")
  stderr.write("m5 cwd-env stderr\n")
  writeFile(FixtureRecord, "cwd=" & cwd & "\nenv=" & envValue & "\n")
  quit 0

if commandLineParams().len == 1 and commandLineParams()[0] == FixtureSleep:
  sleep(5000)
  quit 0

if commandLineParams().len == 1 and commandLineParams()[0] == FixtureExit7:
  quit 7

proc waitForDaemon(socketPath: string) =
  putEnv("RUNQUOTA_SOCKET", socketPath)
  var lastError = ""
  for _ in 0 ..< 100:
    try:
      var client = connectDefault()
      client.close()
      return
    except CatchableError as error:
      lastError = error.msg
      sleep(50)
  raise newException(OSError, "runquotad did not become ready: " & lastError)

proc req(label: string): ResourceRequest =
  resourceRequest(label, milliCpu(100), bytes(1024 * 1024))

proc prepareDir(path: string) =
  if dirExists(path):
    removeDir(path)
  createDir(path)
  # THE MODE THE SHIPPED POLICY REQUIRES, not a literal. This directory is
  # the RENDEZVOUS `runquotad` binds in, and the rendezvous mode is 0750
  # where a `runquota` group exists and 0700 (owner-only, single-user mode)
  # where it does not -- so a fixture hardcoding either one is green on one
  # kind of host and red on the other. Fixture only; the modes themselves
  # are asserted in tests/unit/t_shared_endpoint_rules.nim.
  setFilePermissions(path, endpointDirectoryPermissions())

proc checkCwdEnvRecord(path, expectedEnv: string) =
  let recordPath = path / FixtureRecord
  check fileExists(recordPath)
  let record = readFile(recordPath)
  check record.contains("cwd=")
  check record.contains("env=" & expectedEnv)

proc hasMetricWithExtra(jsonText, namePart, extraPart: string): bool =
  let root = parseJson(jsonText)
  for item in root.items:
    if item{"name"}.getStr().contains(namePart) and
        item{"extra"}.getStr().contains(extraPart):
      return true

suite "m5_process_exec_bench_contract":
  test "benchmark recipes are present":
    let justfile = readFile("Justfile")
    check justfile.contains("bench-runquota-process-execution")
    check justfile.contains("bench-runquota-ipc")
    check fileExists("scripts/run-m5-benchmark.sh")
    check fileExists("benchmarks/lib/runquota_m5_bench.nim")

  test "process helper captures output and cancels process group":
    let profile = backendProfile()
    check profile.directArgv
    check not profile.implicitShell
    check profile.outputCapture.contains("bounded")

    var outputChild = launchProcess(commandSpec([getAppFilename(), FixtureOutput]))
    let output = outputChild.waitForCompletion(3000)
    outputChild.close()
    check output.exited
    check output.exitCode == 0
    check output.stdout.contains("m5 stdout")
    check output.stderr.contains("m5 stderr")
    check output.stdoutBytes > 0
    check output.stderrBytes > 0

    var sleeping = launchProcess(commandSpec([getAppFilename(), FixtureSleep]))
    sleep(50)
    let cancelled = sleeping.cancelAndWait(3000)
    sleeping.close()
    check cancelled.cancelled
    check cancelled.signaled or cancelled.timedOut
    check cancelled.elapsedMillis < 3500

  test "process helper applies cwd and environment to child":
    let cwdDir = getTempDir() / ("runquota-m5-direct-cwd-env-" & $getCurrentProcessId())
    prepareDir(cwdDir)
    try:
      var child = launchProcess(commandSpec(
        [getAppFilename(), FixtureCwdEnv],
        cwd = cwdDir,
        env = [FixtureEnvName & "=direct-cwd-env"],
        stdoutLimit = 4096,
        stderrLimit = 4096
      ))
      let completion = child.waitForCompletion(3000)
      child.close()

      check completion.exited
      check completion.exitCode == 0
      check completion.processId > 0
      check completion.processGroupId > 0
      check completion.stdout.contains("m5 cwd=")
      check completion.stdout.contains("m5 env=direct-cwd-env")
      check completion.stderr.contains("m5 cwd-env stderr")
      check completion.processCount > 0
      checkCwdEnvRecord(cwdDir, "direct-cwd-env")
    finally:
      if dirExists(cwdDir):
        removeDir(cwdDir)

  # The three tests below cover what moved out of the child when the
  # between-fork-and-exec `putEnv` loop was replaced by a `char *[]` built in
  # the parent and handed to `execve`. `execve` takes the environment whole and
  # performs no PATH search of its own, so "overrides reach the child" is no
  # longer the only property that has to hold: the launcher's *own*
  # environment has to survive, an override has to replace rather than
  # duplicate, and the PATH lookup `execvp` used to do inside the child has to
  # still happen -- against the PATH the child was given, not the parent's.

  test "the child's environment is the launcher's, with overrides layered on top":
    putEnv("RUNQUOTA_M5_INHERITED", "from-launcher")
    putEnv("RUNQUOTA_M5_REPLACED", "parent-value")
    var child = launchProcess(commandSpec(
      [getAppFilename(), FixtureEnvDump,
       "RUNQUOTA_M5_INHERITED", "RUNQUOTA_M5_REPLACED", "RUNQUOTA_M5_ADDED",
       "RUNQUOTA_M5_UNSET"],
      env = [
        "RUNQUOTA_M5_REPLACED=child-value",
        "RUNQUOTA_M5_ADDED=added-by-caller"
      ]))
    let completion = child.waitForCompletion(10_000)
    child.close()

    check completion.exited
    check completion.exitCode == 0
    # Inherited, untouched by the override list.
    check completion.stdout.contains("RUNQUOTA_M5_INHERITED=[from-launcher]")
    check completion.stdout.contains("RUNQUOTA_M5_INHERITED occurrences=1")
    # Overridden, not shadowed: the parent value must not survive alongside it.
    # The occurrence count is what makes "replaced" distinguishable from
    # "appended" -- `getenv` would report the first of a duplicated pair and
    # hide the second, so the entry is counted in the child's environment
    # block instead.
    check completion.stdout.contains("RUNQUOTA_M5_REPLACED=[child-value]")
    check not completion.stdout.contains("RUNQUOTA_M5_REPLACED=[parent-value]")
    check completion.stdout.contains("RUNQUOTA_M5_REPLACED occurrences=1")
    # Added, with no inherited entry to replace.
    check completion.stdout.contains("RUNQUOTA_M5_ADDED=[added-by-caller]")
    check completion.stdout.contains("RUNQUOTA_M5_ADDED occurrences=1")
    # A name the caller never mentioned is absent from the child, not present
    # and empty -- the two the fixture can now tell apart.
    check completion.stdout.contains("RUNQUOTA_M5_UNSET=<absent>")
    # The launcher's own environment is not disturbed by having composed the
    # child's: the old implementation mutated it via `putEnv` in the child, so
    # this asserts the replacement did not move that mutation into the parent.
    check getEnv("RUNQUOTA_M5_REPLACED") == "parent-value"
    check getEnv("RUNQUOTA_M5_ADDED") == ""

  test "a bare program name is resolved through the PATH the child is given":
    when defined(posix):
      let binDir = getTempDir() / ("runquota-m5-path-" & $getCurrentProcessId())
      prepareDir(binDir)
      try:
        let probe = binDir / "runquota-m5-path-probe"
        writeFile(probe, "#!/bin/sh\necho \"probe=$RUNQUOTA_M5_PATH_MARK\"\n")
        setFilePermissions(probe, {fpUserRead, fpUserExec})

        # The directory is on the *child's* PATH only; the launcher's PATH does
        # not contain it. `execvp` resolved against the environment the child
        # had after its own `putEnv` calls, so the replacement has to resolve
        # against the composed environment too, not against the parent's.
        check findExe("runquota-m5-path-probe").len == 0
        var child = launchProcess(commandSpec(
          ["runquota-m5-path-probe"],
          env = [
            "PATH=" & binDir,
            "RUNQUOTA_M5_PATH_MARK=resolved-via-child-path"
          ]))
        let completion = child.waitForCompletion(10_000)
        child.close()

        check completion.exited
        check completion.exitCode == 0
        check completion.stdout.contains("probe=resolved-via-child-path")
      finally:
        if dirExists(binDir):
          removeDir(binDir)
    else:
      skip()

  test "argv[0] reaches the child as the caller wrote it, not as it resolved":
    when defined(posix):
      # `execve` needs a resolved path where `execvp` took a bare name, and the
      # obvious way to give it one is to write the resolved path into `argv[0]`
      # on the way past. `execvp` never did that, and callers can see the
      # difference: `$0`, `ps` output, and multi-call binaries that dispatch on
      # their own name. Invoke by a bare name that only resolves through the
      # child's PATH, so resolution has something to rewrite, and check that it
      # left `argv[0]` alone.
      let binDir = getTempDir() / ("runquota-m5-argv0-" & $getCurrentProcessId())
      prepareDir(binDir)
      try:
        let probeName = "runquota-m5-argv0-probe"
        createSymlink(getAppFilename(), binDir / probeName)
        var child = launchProcess(commandSpec(
          [probeName, FixtureArgv0], env = ["PATH=" & binDir]))
        let completion = child.waitForCompletion(10_000)
        child.close()

        check completion.exited
        check completion.exitCode == 0
        check completion.stdout.contains("argv0=[" & probeName & "]")
      finally:
        if dirExists(binDir):
          removeDir(binDir)
    else:
      skip()

  test "a program the kernel cannot exec directly still runs through the shell":
    when defined(posix):
      # No shebang: the kernel answers ENOEXEC. `execvp` retried such a file
      # through `/bin/sh`, and dropping that when moving to `execve` would have
      # silently broken every caller that relies on it.
      let scriptDir = getTempDir() / ("runquota-m5-noexec-" & $getCurrentProcessId())
      prepareDir(scriptDir)
      try:
        let script = scriptDir / "runquota-m5-shebangless"
        writeFile(script, "echo \"shebangless=$1\"\n")
        setFilePermissions(script, {fpUserRead, fpUserExec})

        var child = launchProcess(commandSpec([script, "ran-anyway"]))
        let completion = child.waitForCompletion(10_000)
        child.close()

        check completion.exited
        check completion.exitCode == 0
        check completion.stdout.contains("shebangless=ran-anyway")
      finally:
        if dirExists(scriptDir):
          removeDir(scriptDir)
    else:
      skip()

  test "process running predicate does not consume completion status":
    var child = launchProcess(commandSpec([getAppFilename(), FixtureExit7]))
    sleep(100)
    discard child.running()
    discard child.running()
    let completion = child.waitForCompletion(3000)
    child.close()

    check completion.exited
    check completion.exitCode == 7

  test "pollCompletion reports externally reaped child as failure":
    when defined(posix):
      var child = launchProcess(commandSpec([getAppFilename(), FixtureExit7]))
      var status: cint = 0
      discard waitpid(Pid(child.pid), status, 0)

      var done = false
      for _ in 0 ..< 200:
        if child.pollCompletion():
          done = true
          break
        sleep(5)
      let completion = child.completion
      child.close()

      check done
      check completion.exited
      check completion.exitCode == 1
    else:
      skip()

  test "lease-bound helper and CLI use real daemon protocol":
    let socketDir = getTempDir() / ("runquota-m5-test-" & $getCurrentProcessId())
    let socketPath = socketDir / "runquotad.sock"
    if dirExists(socketDir):
      removeDir(socketDir)
    createDir(socketDir)
    # THE MODE THE SHIPPED POLICY REQUIRES, not a literal. This directory is
    # the RENDEZVOUS `runquotad` binds in, and the rendezvous mode is 0750
    # where a `runquota` group exists and 0700 (owner-only, single-user mode)
    # where it does not -- so a fixture hardcoding either one is green on one
    # kind of host and red on the other. Fixture only; the modes themselves
    # are asserted in tests/unit/t_shared_endpoint_rules.nim.
    setFilePermissions(socketDir, endpointDirectoryPermissions())
    check fileExists(daemonPath())
    check fileExists(cliPath())

    let daemon = startProcess(
      daemonPath(),
      args = [
        "--socket", socketPath,
        "--cpu-milli", "2000",
        "--memory-bytes", $((1024'u64 * 1024'u64 * 1024'u64))
      ],
      options = {poStdErrToStdOut}
    )
    try:
      waitForDaemon(socketPath)
      var client = connectDefault()
      var session = client.registerSession("m5-helper-contract", versionString())

      let leaseCwdDir = socketDir / "lease-cwd-env"
      prepareDir(leaseCwdDir)
      let beforeLease = client.daemonStatus().totalFinished
      let execution = session.runWithLease(
        req("helper-cwd-env-output"),
        [getAppFilename(), FixtureCwdEnv],
        cwd = leaseCwdDir,
        env = [FixtureEnvName & "=lease-cwd-env"],
        stdoutLimit = 4096,
        stderrLimit = 4096
      )
      check execution.leaseFinishedSent
      check execution.leaseReleased
      check execution.backend.name == backendProfile().name
      check execution.backend.directArgv
      check not execution.backend.implicitShell
      check execution.process.exited
      check execution.process.exitCode == 0
      check execution.process.processId > 0
      check execution.process.processGroupId > 0
      check execution.process.processCount > 0
      check execution.process.stdout.contains("m5 cwd=")
      check execution.process.stdout.contains("m5 env=lease-cwd-env")
      check execution.process.stderr.contains("m5 cwd-env stderr")
      check execution.process.stdoutBytes > 0
      check execution.process.stderrBytes > 0
      check client.daemonStatus().totalFinished > beforeLease
      checkCwdEnvRecord(leaseCwdDir, "lease-cwd-env")

      let beforeCli = client.daemonStatus().totalFinished
      # `runCapturedProcess`, not `execProcess`: the latter reads stdout and
      # no other stream, and the explicit `options` here replaces its
      # `poStdErrToStdOut` default, so stderr sat on a pipe nobody read. The
      # fixture's own diagnostics go there, and a pipe holds only 65_536 bytes.
      let cliCaptured = runCapturedProcess(
        cliPath(),
        args = [
          "acquire",
          "--cpu", "100",
          "--mem", "1MiB",
          "--label", "cli-helper-output",
          "--",
          getAppFilename(),
          FixtureOutput
        ],
        env = nil,
        options = {poUsePath}
      )
      if not cliCaptured.ok:
        checkpoint("runquota acquire stderr: " & cliCaptured.error)
      check cliCaptured.failure.len == 0
      check cliCaptured.output.contains("m5 stdout")
      check client.daemonStatus().totalFinished > beforeCli

      session.closeSession()
      client.close()
    finally:
      if daemon.running:
        daemon.terminate()
        discard daemon.waitForExit(3000)
      daemon.close()
      if dirExists(socketDir):
        removeDir(socketDir)

  test "process benchmark quick path emits cwd env workload evidence":
    # This runs a BUILD SCRIPT -- `nim c` of the benchmark, then the benchmark
    # itself -- through a helper that used to read stdout and nothing else.
    # The script routes the compiler's own stdout to /dev/null but not its
    # stderr, so every compiler diagnostic lands on a pipe that `execProcess`
    # would never have read. A clean run measures 6_177 bytes there, which is
    # a tenth of the 65_536 a pipe holds -- but the amount is a function of how
    # much the compiler has to say, so the first genuinely noisy build would
    # not have failed this test, it would have HUNG it, and hung it with the
    # compiler's explanation still sitting unread in the pipe.
    let captured = runCapturedProcess(
      "scripts/run-m5-benchmark.sh",
      args = ["process", "--quick"],
      options = {poUsePath}
    )
    # The script's diagnostics are now readable, so a failed build says why
    # instead of failing three opaque metric assertions below.
    if not captured.ok:
      checkpoint("run-m5-benchmark.sh stderr: " & captured.error)
    check captured.failure.len == 0
    check captured.exitCode == 0
    let output = captured.output
    check hasMetricWithExtra(output, "raw-cwd-env fixture", "cwd_env=verified")
    check hasMetricWithExtra(output, "lease-cwd-env fixture", "cwd_env=verified")
    check hasMetricWithExtra(output, "lease-output-capture bytes", "LeaseFinished=true")
