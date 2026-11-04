## No mocks: this binary runs as a captured parent, an inherited-stdio
## supervisor and its real child. The outer pipes observe actual forwarded
## stdin/stdout/stderr independently of the process helper's completion.
import std/[os, osproc, streams, strutils, unittest]

import runquota_process

const
  EmitArgument = "--emit-bounded-output"
  PrefixLength = 4096
  TerminalDiagnostic = "terminal-diagnostic\n"

if paramCount() == 1 and paramStr(1) == EmitArgument:
  stdout.write('a'.repeat(PrefixLength))
  stdout.write(TerminalDiagnostic)
  stdout.flushFile()
  quit(7)

const
  InheritedInner = "--inherited-stdio-inner"
  InheritedOuter = "--inherited-stdio-outer"

if paramCount() == 1 and paramStr(1) == InheritedInner:
  stdout.write("inherited-input=" & stdin.readLine() & "\n")
  stderr.write("inherited-stderr\n")
  stdout.flushFile()
  stderr.flushFile()
  quit(7)

if paramCount() == 1 and paramStr(1) == InheritedOuter:
  var child = launchProcess(commandSpec([getAppFilename(), InheritedInner],
    stdio = inheritStdio))
  let completion = child.waitForCompletion(10_000)
  child.close()
  if not completion.exited or completion.exitCode != 7 or
      completion.stdout.len != 0 or completion.stderr.len != 0 or
      completion.stdoutBytes != 0 or completion.stderrBytes != 0:
    quit(9)
  stdout.write("inherited-completion-empty\n")
  stdout.flushFile()
  quit(completion.exitCode)

suite "bounded process output":
  test "retains the terminal diagnostic and the true byte count":
    const captureLimit = 64
    var child = launchProcess(commandSpec(
      [getAppFilename(), EmitArgument],
      stdoutLimit = captureLimit,
      stderrLimit = captureLimit))
    defer: child.close()

    let completion = child.waitForCompletion(timeout = 10_000)
    check completion.exited
    check completion.exitCode == 7
    check completion.stdoutBytes == uint64(
      PrefixLength + TerminalDiagnostic.len)
    check completion.stdout.len == captureLimit
    check completion.stdout.endsWith(TerminalDiagnostic)

  test "inherits all standard streams without capturing them or changing status":
    let outer = startProcess(getAppFilename(), args = [InheritedOuter],
      options = {})
    defer: outer.close()
    outer.inputStream.write("real-parent-input\n")
    outer.inputStream.flush()
    outer.inputStream.close()
    let actualStdout = outer.outputStream.readAll()
    let actualStderr = outer.errorStream.readAll()
    check outer.waitForExit() == 7
    check actualStdout == "inherited-input=real-parent-input\n" &
      "inherited-completion-empty\n"
    check actualStderr == "inherited-stderr\n"
