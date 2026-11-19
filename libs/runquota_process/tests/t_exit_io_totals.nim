## The storage bytes a launcher reports for a tree (`sizing-data`): what the
## tree wrote is in the completion's `io`, in bytes, for a root whose
## waited-for child did the writing.
##
## THE PROPERTY, AND THE LAUNCHER IT IS ABOUT. A launcher that is NOT ROOT
## must get this figure on Linux. Once a task has exited, Linux shows its
## `/proc/<pid>` files as owned by root, and `io` is mode 0400, so the
## task's own parent is refused the read (EACCES; measured on Linux 6.18).
## That file is where the launcher used to read the figure, so every
## execution's `io_write_bytes` was NULL (reprobuild-pm
## `issues/2026-11-18-runquota-cannot-read-an-exited-roots-proc-io-so-linux-write-bytes-are-never-measured.md`).
## The launcher now takes the figure from the `wait4` that reaps the root
## (`ru_inblock` / `ru_oublock`, 512-byte units), which has no access check.
##
## Falsifying mutations:
## * reading the exited root's `/proc/<pid>/io` instead: `io.known` is false
##   for a launcher that is not root. ROOT CAN READ THAT FILE, so a run as
##   root cannot tell the two routes apart; the case says so in its output
##   when it runs as root, and the suite is normally run by an ordinary
##   user;
## * dropping the `* 512`: the figure is 512 times too small and fails the
##   lower bound;
## * reporting without `sizing-data`: fails the control case.
##
## On macOS the figure is the root's own bytes (no reaped-children share),
## so the root is the writer itself there.
##
## NO MOCKS: the real launcher, real children (this binary re-executed),
## real writes that are fsynced, the kernel's own accounting. The counters
## count bytes sent to storage, so the file must be on a disk-backed
## filesystem: `RUNQUOTA_TEST_DISK_DIR`, else the working directory. On
## tmpfs the case fails, naming the directory, rather than skips.
import std/[os, strutils, unittest]

import runquota_process

const
  WriteMiB = 8
  WriteArgument = "--write-synced"
  MiB = 1024'u64 * 1024'u64

when defined(linux) or defined(macosx):
  import std/posix

  proc writeSynced(path: string; mib: int) =
    let fd = posix.open(path.cstring, O_WRONLY or O_CREAT or O_TRUNC, 0o600)
    doAssert fd >= 0, "cannot create " & path
    var chunk = newSeq[byte](1024 * 1024)
    for i in 0 ..< chunk.len:
      chunk[i] = byte(i and 0xff)
    for _ in 0 ..< mib:
      var done = 0
      while done < chunk.len:
        let n = posix.write(fd, addr chunk[done], chunk.len - done)
        doAssert n > 0, "write failed"
        done += n
    doAssert fsync(fd) == 0, "fsync failed"
    discard posix.close(fd)

  if paramCount() == 3 and paramStr(1) == WriteArgument:
    writeSynced(paramStr(2), parseInt(paramStr(3)))
    quit(0)

  proc runWriter(target: string): ProcessCompletion =
    let writer = quoteShell(getAppFilename()) & " " & WriteArgument & " " &
      quoteShell(target) & " " & $WriteMiB
    # Linux: the writer is a CHILD of the root shell, which waits for it
    # (the `; exit 0` keeps the shell from exec'ing it in place). macOS has
    # no reaped-children share, so the root is the writer.
    let script =
      when defined(linux): writer & "; exit 0" else: "exec " & writer
    var child = launchProcess(commandSpec(["/bin/sh", "-c", script]))
    result = child.waitForCompletion(60_000)
    child.close()

  when defined(linux):
    proc statfs(path: cstring; buf: pointer): cint {.importc: "statfs",
      header: "<sys/vfs.h>".}

  proc onTmpfs(dir: string): bool =
    ## tmpfs sends nothing to storage, so the kernel counts no bytes there.
    when defined(linux):
      const tmpfsMagic = 0x01021994'u64
      # `struct statfs` starts with `f_type` (a long) on Linux.
      var fs: array[128, int64]
      statfs(dir.cstring, addr fs[0]) == 0 and uint64(fs[0]) == tmpfsMagic
    else:
      false

  suite "exit io totals":
    let dir = getEnv("RUNQUOTA_TEST_DISK_DIR", getCurrentDir())
    let target = dir / ("rq-exit-io-" & $getCurrentProcessId())
    let measurementBefore = getEnv("RUNQUOTA_MEASUREMENT")
    let measurementWasSet = existsEnv("RUNQUOTA_MEASUREMENT")

    teardown:
      if measurementWasSet:
        putEnv("RUNQUOTA_MEASUREMENT", measurementBefore)
      else:
        delEnv("RUNQUOTA_MEASUREMENT")

    test "sizing-data: a waited-for child's writes are in the root's totals":
      require(not onTmpfs(dir))  # set RUNQUOTA_TEST_DISK_DIR to a disk
      if getuid() == Uid(0):
        echo "    NOTE: running as root, which can also read an exited ",
          "child's /proc io; this run does not tell the two routes apart"
      putEnv("RUNQUOTA_MEASUREMENT", "sizing-data=on")
      defer: removeFile(target)
      let completion = runWriter(target)
      check completion.exited
      check completion.exitCode == 0
      checkpoint "launcher uid " & $getuid() & ", io known " &
        $completion.io.known & ", written " & $completion.io.writeBytes &
        ", read " & $completion.io.readBytes
      check completion.io.known
      let written = uint64(WriteMiB) * MiB
      # At least what was written and fsynced; the shell and the runtime add
      # a little, never a multiple.
      check completion.io.writeBytes >= written
      check completion.io.writeBytes < written * 2'u64

    test "without sizing-data no io totals are reported":
      putEnv("RUNQUOTA_MEASUREMENT", "sizing-data=off")
      defer: removeFile(target)
      let completion = runWriter(target)
      check completion.exited
      check completion.exitCode == 0
      check not completion.io.known
