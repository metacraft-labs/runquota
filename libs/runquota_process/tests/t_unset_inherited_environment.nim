## `CommandSpec.unsetEnv`: an inheriting child does not see a name the caller
## removed, while every other inherited name still reaches it, and an explicit
## `env` entry for the same name still sets it.
##
## Layering (`CommandSpec.env` over the launcher's environment) can replace a
## variable but never remove one. A caller that keeps a build-tool selection
## variable such as `CC` away from a child, without giving up the rest of the
## inherited environment, needs the removal this exercises.
##
## The instrument is the child itself: this binary re-executed with a marker
## argument prints its own environment. The launcher sets all three variables;
## the child must lack the removed one, see the untouched one, and see the
## overridden one at its explicit value.
##
## MOCKS: none. Real processes, launched by the production launcher.

import std/[os, strutils, unittest]

import runquota_process

const
  DumpArgument = "--dump-environment"
  Removed = "RQ_TEST_UNSET_REMOVED"
  Kept = "RQ_TEST_UNSET_KEPT"
  Overridden = "RQ_TEST_UNSET_OVERRIDDEN"
  OverriddenValue = "declared"

if paramCount() == 1 and paramStr(1) == DumpArgument:
  for key, value in envPairs():
    stdout.write(key & "=" & value & "\n")
  stdout.flushFile()
  quit(0)

proc childEnvironment(unset: openArray[string]): string =
  var child = launchProcess(commandSpec(
    [getAppFilename(), DumpArgument],
    env = [Overridden & "=" & OverriddenValue],
    unsetEnv = unset))
  defer: child.close()
  let completion = child.waitForCompletion(timeout = 10_000)
  check completion.exited
  check completion.exitCode == 0
  completion.stdout

suite "unset inherited environment":
  putEnv(Removed, "leaks")
  putEnv(Kept, "kept")
  putEnv(Overridden, "from-the-launcher")

  test "a removed name is absent from the child, and nothing else is":
    let dump = childEnvironment([Removed])
    check (Removed & "=") notin dump
    check (Kept & "=kept") in dump

  test "a name the caller both removes and sets takes the explicit value":
    let dump = childEnvironment([Overridden])
    check (Overridden & "=" & OverriddenValue) in dump
    check (Overridden & "=from-the-launcher") notin dump

  test "without unsetEnv the launcher's value reaches the child":
    let dump = childEnvironment([])
    check (Removed & "=leaks") in dump
