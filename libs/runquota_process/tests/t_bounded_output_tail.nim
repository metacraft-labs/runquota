import std/[os, strutils, unittest]

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
