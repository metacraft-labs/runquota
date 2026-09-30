## `CommandSpec.inheritEnv` decides whether a child starts from the launcher's
## environment. Layering alone can replace a variable but never remove one, so
## a caller that must control exactly what a process can observe needs the
## child to start from nothing but its own entries.

import std/[os, strutils, unittest]

import runquota_process

const
  ReportArgument = "--report-env"
  Marker = "RUNQUOTA_T_INHERIT_MARKER"
  Declared = "RUNQUOTA_T_DECLARED"

if paramCount() == 2 and paramStr(1) == ReportArgument:
  let name = paramStr(2)
  stdout.write(if existsEnv(name): name & "=" & getEnv(name) else: name & " unset")
  stdout.flushFile()
  quit(0)

proc report(name: string; inheritEnv: bool; env: openArray[string]): string =
  var child = launchProcess(commandSpec([getAppFilename(), ReportArgument, name],
    env = env, inheritEnv = inheritEnv))
  defer: child.close()
  let completion = child.waitForCompletion(timeout = 10_000)
  check completion.exited
  check completion.exitCode == 0
  completion.stdout.strip()

proc essentials(): seq[string] =
  ## What any Windows process needs to start at all; POSIX needs nothing.
  when defined(windows):
    for name in ["SystemRoot", "SystemDrive", "windir", "TEMP", "TMP"]:
      if existsEnv(name):
        result.add(name & "=" & getEnv(name))

suite "child environment inheritance":
  putEnv(Marker, "from-launcher")

  test "by default the launcher's environment is inherited":
    check commandSpec(["x"]).inheritEnv
    check report(Marker, true, []) == Marker & "=from-launcher"

  test "declared entries are layered over the inherited ones":
    check report(Marker, true, [Marker & "=overridden"]) ==
      Marker & "=overridden"

  test "without inheritance the child sees only its own entries":
    let env = essentials() & @[Declared & "=declared"]
    check report(Marker, false, env) == Marker & " unset"
    check report(Declared, false, env) == Declared & "=declared"
