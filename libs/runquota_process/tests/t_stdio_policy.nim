## Real re-executed processes qualify capture and inherited stdin/out/err.
## The outer osproc pipes provide observable caller streams, not a mock
## launcher. The inner process uses runquota_process directly in both modes.
import std/[os, osproc, streams, strutils, tempfiles, unittest]
import runquota_process
when defined(posix):
  import std/posix

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
