## No mocks: launch this real executable through RunQuota and inspect the
## child's OS environment block, including duplicate entries and casing.
when defined(windows):
  import std/[os, strutils, unittest]
  import runquota_process

  const
    ParentName = "RunQuota_Test_Mixed_Case"
    UpperName = "RUNQUOTA_TEST_MIXED_CASE"
    LowerName = "runquota_test_mixed_case"
    ChildFlag = "--dump-child-environment"

  if commandLineParams() == @[ChildFlag]:
    var count = 0
    for key, value in envPairs():
      if cmpIgnoreCase(key, ParentName) == 0:
        inc count
        echo "entry=", value
    echo "matches=", count
    echo "lookup=", getEnv(UpperName)
    quit(0)

  suite "Windows child environment":
    test "case variants replace inherited entries and preserve the parent":
      let existed = existsEnv(ParentName)
      let original = getEnv(ParentName)
      putEnv(ParentName, "parent-value")
      defer:
        if existed: putEnv(ParentName, original)
        else: delEnv(ParentName)

      var child = launchProcess(commandSpec(
        [getAppFilename(), ChildFlag],
        env = [UpperName & "=first-override", LowerName & "=last-override"]))
      let completion = child.waitForCompletion(10_000)
      child.close()
      checkpoint(completion.stdout)
      check completion.exited
      check completion.exitCode == 0
      check "matches=1" in completion.stdout
      check "entry=last-override" in completion.stdout
      check "lookup=last-override" in completion.stdout
      check "entry=parent-value" notin completion.stdout
      check "entry=first-override" notin completion.stdout
      check getEnv(UpperName) == "parent-value"
