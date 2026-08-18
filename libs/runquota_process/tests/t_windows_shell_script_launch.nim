import std/[os, osproc, strutils, tempfiles, unittest]

import runquota_process

proc runForwarder(): int =
  let params = commandLineParams()
  if params.len == 0 or params[0] != "forward-after-double-dash":
    return -1
  let separator = params.find("--")
  if separator < 0 or separator + 1 >= params.len:
    return 2
  let command = params[separator + 1]
  let args =
    if separator + 2 < params.len: params[separator + 2 .. ^1]
    else: @[]
  let child = startProcess(command, args = args, options = {poUsePath})
  result = child.waitForExit()
  child.close()

let forwarderExit = runForwarder()
if forwarderExit >= 0:
  quit forwarderExit

proc longShellProgram(resultName: string): string =
  result = "set -e\n"
  for _ in 0 ..< 180:
    result.add(
      "for value in 'format=%s' 'percent=100%literal%' " &
      "'caret=^left^right' 'slashes=C:\\tmp\\zlib'; do " &
      ": \"$value\"; done\n")
  result.add(
    "printf '%s\\n' \"$0\" \"$1\" \"$2\" > " & resultName & "\n")

suite "Windows shell command launch":
  when defined(windows):
    test "long -c programs preserve syntax, arguments, and cleanup":
      let shell = findExe("sh")
      if shell.len == 0:
        checkpoint("POSIX shell is not installed; launch probe skipped")
      else:
        let workDir = createTempDir("runquota-shell-test-", "")
        defer:
          if dirExists(workDir):
            removeDir(workDir)

        let shellProgram = longShellProgram("result.txt")
        check shellProgram.len > 10_000

        var child = launchProcess(commandSpec([
          shell,
          "-c",
          shellProgram,
          "declared-zero",
          "first",
          "second value",
        ], cwd = workDir))
        let stagedFiles = child.temporaryLaunchFiles
        check stagedFiles.len == 1
        check fileExists(stagedFiles[0])

        let completion = child.waitForCompletion(10_000)
        child.close()

        check completion.exited
        check completion.exitCode == 0
        check readFile(workDir / "result.txt").strip().splitLines() == @[
          "declared-zero",
          "first",
          "second value",
        ]
        check not fileExists(stagedFiles[0])

    test "long nested -c programs survive a double-dash wrapper":
      let shell = findExe("sh")
      if shell.len == 0:
        checkpoint("POSIX shell is not installed; launch probe skipped")
      else:
        let workDir = createTempDir("runquota-wrapped-shell-test-", "")
        defer:
          if dirExists(workDir):
            removeDir(workDir)

        let shellProgram = longShellProgram("wrapped-result.txt")
        var child = launchProcess(commandSpec([
          getAppFilename(),
          "forward-after-double-dash",
          "--depfile",
          "ignored.rdep",
          "--",
          shell,
          "-c",
          shellProgram,
          "wrapped-zero",
          "wrapped-first",
          "wrapped second",
        ], cwd = workDir))
        let stagedFiles = child.temporaryLaunchFiles
        check stagedFiles.len == 1
        check fileExists(stagedFiles[0])

        let completion = child.waitForCompletion(10_000)
        child.close()

        check completion.exited
        check completion.exitCode == 0
        check readFile(workDir / "wrapped-result.txt").strip().splitLines() == @[
          "wrapped-zero",
          "wrapped-first",
          "wrapped second",
        ]
        check not fileExists(stagedFiles[0])
  else:
    test "shell staging is Windows-only":
      skip()
