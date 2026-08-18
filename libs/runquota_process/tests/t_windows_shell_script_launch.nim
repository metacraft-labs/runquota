import std/[os, strutils, tempfiles, unittest]

import runquota_process

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

        var shellProgram = "set -e\n"
        for _ in 0 ..< 180:
          shellProgram.add(
            "for value in 'format=%s' 'percent=100%literal%' " &
            "'caret=^left^right' 'slashes=C:\\tmp\\zlib'; do " &
            ": \"$value\"; done\n")
        shellProgram.add(
          "printf '%s\\n' \"$0\" \"$1\" \"$2\" > result.txt\n")
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
  else:
    test "shell staging is Windows-only":
      skip()
