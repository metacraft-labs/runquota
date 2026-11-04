## Real re-executed processes qualify capture and inherited stdin/out/err.
## The outer osproc pipes provide observable caller streams, not a mock
## launcher. The inner process uses runquota_process directly in both modes.
import std/[os, osproc, streams, strutils, tempfiles, unittest]
import runquota_process
when defined(posix):
  import std/posix

# Linux alone exposes the per-process seccomp boundary used by the additive
# setup-error cases below. The original capture/inherit cases still run on
# every supported platform. No syscall mock or product injection seam is used:
# a dedicated re-executed driver installs a kernel filter inherited only by
# its own children. It deliberately denies setpgid with EPERM and allows all
# other syscalls. The test executes only this same native binary, so no
# cross-architecture syscall ABI enters this narrowly scoped error fixture.
when defined(linux):
  {.emit: """
#include <errno.h>
#include <stddef.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
static int runquotaTestInstallSetpgidFailureFilter(void) {
    struct sock_filter instructions[] = {
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr)),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, SYS_setpgid, 0, 1),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | EPERM),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
    };
    struct sock_fprog program = {
        .len = sizeof(instructions) / sizeof(instructions[0]),
        .filter = instructions,
    };
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) return errno;
    if (prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &program) != 0) return errno;
    return 0;
}
""".}
  proc installSetpgidFailureFilter(): cint {.
    importc: "runquotaTestInstallSetpgidFailureFilter", nodecl.}

  const
    GroupFailureDriver = "--setpgid-failure-driver"
    GroupFailurePayload = "--setpgid-failure-payload"

  if paramCount() == 2 and paramStr(1) == GroupFailurePayload:
    writeFile(paramStr(2) / "payload-executed", "actual payload ran\n")
    stdout.write("payload stdout\n")
    stderr.write("payload stderr\n")
    quit(37)

  if paramCount() == 3 and paramStr(1) == GroupFailureDriver:
    let work = paramStr(3)
    let installed = installSetpgidFailureFilter()
    if installed != 0:
      stderr.write("seccomp installation failed, errno=" & $installed & "\n")
      quit(90)
    # A filter that was not installed or matched the wrong syscall must not
    # manufacture acceptance. Observe the real kernel refusal before launch.
    let refused = setpgid(0, 0)
    let refusedErrno = errno
    if refused != -1 or refusedErrno != EPERM:
      stderr.write("setpgid preflight was not EPERM: result=" & $refused &
        " errno=" & $refusedErrno & "\n")
      quit(91)
    writeFile(work / "filter-ready", "real kernel setpgid EPERM\n")
    let policy = if paramStr(2) == "inherit": inheritStdio else: captureStdio
    var child = launchProcess(commandSpec(
      [getAppFilename(), GroupFailurePayload, work],
      stdio = policy, createProcessGroup = true))
    defer: child.close()
    let completion = child.waitForCompletion(10_000)
    writeFile(work / "completion",
      "exited=" & $completion.exited & "\n" &
      "exitCode=" & $completion.exitCode & "\n" &
      "signaled=" & $completion.signaled & "\n" &
      "cancelled=" & $completion.cancelled & "\n" &
      "timedOut=" & $completion.timedOut & "\n")
    quit(if completion.exited: completion.exitCode else: 92)

const Argument = "literal argument ; $with spaces"

if paramCount() == 4 and paramStr(1) == "--stdio-leaf":
  let inherited = paramStr(2) == "inherit"
  doAssert paramStr(4) == Argument
  when defined(posix):
    writeFile(paramStr(3) / "group", $getCurrentProcessId() & " " & $getpgrp())
  let input = if inherited: stdin.readLine() else: "captured"
  stdout.write("stdout:" & input & ":" & paramStr(4))
  stderr.write("stderr:" & input)
  quit(23)

if paramCount() == 3 and paramStr(1) == "--stdio-driver":
  let inherited = paramStr(2) == "inherit"
  let work = paramStr(3)
  var spec = commandSpec([getAppFilename(), "--stdio-leaf", paramStr(2),
    work, Argument])
  # The capture path deliberately does not set stdio: it qualifies the default.
  if inherited:
    spec.stdio = inheritStdio
  var child = launchProcess(spec)
  defer: child.close()
  when defined(posix):
    doAssert (child.stdoutFd == -1) == inherited
    doAssert (child.stderrFd == -1) == inherited
  let completion = child.waitForCompletion()
  doAssert completion.exitCode == 23
  doAssert completion.exited
  doAssert not completion.cancelled
  when defined(posix):
    let group = readFile(work / "group").splitWhitespace()
    doAssert parseInt(group[0]) == child.pid
    doAssert parseInt(group[1]) == child.pid
    doAssert child.processGroupId == child.pid
  if inherited:
    doAssert completion.stdout.len == 0
    doAssert completion.stderr.len == 0
    doAssert completion.stdoutBytes == 0
    doAssert completion.stderrBytes == 0
  else:
    doAssert completion.stdout == "stdout:captured:" & Argument
    doAssert completion.stderr == "stderr:captured"
    doAssert completion.stdoutBytes == uint64(completion.stdout.len)
    doAssert completion.stderrBytes == uint64(completion.stderr.len)
  quit(completion.exitCode)

suite "process stdio policy":
  for mode in ["capture", "inherit"]:
    test mode & " preserves streams, argv, status and child-owned group":
      let work = createTempDir("runquota_stdio_", "")
      defer: removeDir(work)
      let driver = startProcess(getAppFilename(),
        args = ["--stdio-driver", mode, work], options = {})
      defer: driver.close()
      driver.inputStream.writeLine("inherited-input")
      driver.inputStream.close()
      let output = driver.outputStream.readAll()
      let errors = driver.errorStream.readAll()
      check driver.waitForExit() == 23
      if mode == "inherit":
        check output == "stdout:inherited-input:" & Argument
        check errors == "stderr:inherited-input"
      else:
        check output == ""
        check errors == ""

  when defined(linux):
    for mode in ["capture", "inherit"]:
      test mode & " refuses payload when child process-group setup fails":
        let work = createTempDir("runquota_setpgid_failure_", "")
        defer: removeDir(work)
        # Create the driver's group BEFORE it installs its private filter.
        # This outer successful group also bounds cleanup on an unexpected
        # timeout; the suite process and other cases never receive the filter.
        var driver = launchProcess(commandSpec(
          [getAppFilename(), GroupFailureDriver, mode, work],
          createProcessGroup = true))
        defer: driver.close()
        let completed = driver.waitForCompletion(15_000)
        checkpoint("driver stdout: " & completed.stdout)
        checkpoint("driver stderr: " & completed.stderr)
        require completed.exited
        check not completed.signaled
        check not completed.cancelled
        check not completed.timedOut
        check completed.exitCode == 126
        require fileExists(work / "filter-ready")
        check readFile(work / "filter-ready") == "real kernel setpgid EPERM\n"
        require fileExists(work / "completion")
        check readFile(work / "completion") ==
          "exited=true\nexitCode=126\nsignaled=false\n" &
          "cancelled=false\ntimedOut=false\n"
        check not fileExists(work / "payload-executed")
