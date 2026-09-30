## `CommandSpec.inheritEnv = false`: a child launched isolated sees the
## declared environment and nothing the launcher inherited.
##
## A caller that composes an action's whole environment (reprobuild's
## provider compile, Dev-Env-Warm-Entry.md §2) needs the launcher to stop
## layering its own environment underneath: otherwise a variable nobody
## declared still reaches the child, and anything the child reads from it is
## an input nobody recorded.
##
## The instrument is the child itself: this binary re-executed with a marker
## argument prints its own environment. A variable set only in the LAUNCHER
## must reach an inheriting child and must not reach an isolated one, so the
## two cases disagree exactly on the property under test.
##
## MOCKS: none. Real processes, launched by the production launcher.

import std/[algorithm, os, strutils, unittest]

import runquota_process

const
  DumpArgument = "--dump-environment"
  LauncherOnly = "RQ_TEST_LAUNCHER_ONLY"
  Declared = "RQ_TEST_DECLARED"

when defined(windows):
  # x64-on-ARM Windows adds/normalizes this reserved variable even when
  # CreateProcessW receives an explicit environment block. Declare the target
  # architecture so the exact comparison still rejects every undeclared key.
  const WindowsArchitecture =
    when defined(amd64): "AMD64"
    elif defined(arm64): "ARM64"
    else: "x86"
  const DeclaredEnvironment = [Declared & "=yes",
    "PROCESSOR_ARCHITECTURE=" & WindowsArchitecture]
else:
  const DeclaredEnvironment = [Declared & "=yes"]

if paramCount() == 1 and paramStr(1) == DumpArgument:
  for key, value in envPairs():
    stdout.write(key & "=" & value & "\n")
  stdout.flushFile()
  quit(0)

proc childEnvironment(isolate: bool): string =
  var child = launchProcess(commandSpec(
    [getAppFilename(), DumpArgument],
    env = DeclaredEnvironment,
    inheritEnv = not isolate))
  defer: child.close()
  let completion = child.waitForCompletion(timeout = 10_000)
  check completion.exited
  check completion.exitCode == 0
  completion.stdout

suite "isolated child environment":
  putEnv(LauncherOnly, "leaks")

  test "an inheriting child sees the launcher's environment and the declared one":
    let dump = childEnvironment(isolate = false)
    check (LauncherOnly & "=leaks") in dump
    for entry in DeclaredEnvironment:
      check entry in dump

  test "an isolated child sees ONLY the declared environment":
    let dump = childEnvironment(isolate = true)
    check (LauncherOnly & "=") notin dump
    var entries: seq[string] = @[]
    for line in dump.splitLines():
      if line.len > 0:
        entries.add(line)
    var expected = @DeclaredEnvironment
    entries.sort()
    expected.sort()
    check entries == expected
