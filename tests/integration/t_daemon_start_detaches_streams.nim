## `runquota daemon start` must not hand the daemon it starts its own streams.
##
## The verb used to spawn `runquotad` with `poParentStreams`, so the detached
## daemon held the verb's stdout and stderr for as long as it ran. Anything
## that read the verb's output to end of file therefore waited for the daemon
## to exit, which it does not do. Observed 2026-09-28 on Windows:
## `runquota daemon start 2>&1 | tail -5` returned only when the daemon it had
## started was stopped by hand, and the daemon's startup lines went to the
## caller's terminal.
##
## The verb now gives the daemon `--log-file`, which `runquotad` applies before
## it prints anything, and passes any further flags through to it, which is
## what lets this test start one isolated from the host's state
## (`--no-write-stats`, a private endpoint through `RUNQUOTA_SOCKET`).
##
## Revert `runDaemonStart` to `poParentStreams` and the first case fails: the
## verb's output never reaches end of file within the deadline.

import std/[os, osproc, streams, strutils, tempfiles, times, unittest]

import runquota_ipc

import ../support/daemon_binary
import ../support/daemon_endpoint

when defined(windows):
  import std/winlean

  proc getNamedPipeServerProcessId(pipe: Handle; pid: ptr uint32): WINBOOL
    {.stdcall, dynlib: "kernel32", importc: "GetNamedPipeServerProcessId".}

  proc daemonPid(socketPath: string): int =
    ## The pid serving the pipe `socketPath` maps to, asked of the pipe
    ## itself: a named pipe knows which process created its server end.
    let pipe = createFileW(newWideCString(endpointForPath(socketPath).path),
      GENERIC_READ or GENERIC_WRITE, 0, nil, OPEN_EXISTING, 0, 0)
    if pipe == INVALID_HANDLE_VALUE:
      return 0
    defer: discard closeHandle(pipe)
    var pid: uint32
    if getNamedPipeServerProcessId(pipe, addr pid) == 0:
      return 0
    int(pid)
else:
  import std/posix
  import ../support/child_watchdog

  proc daemonPid(socketPath: string): int =
    ## The daemon started against this run's unique directory, found by its
    ## command line (`--log-file` names a file inside that directory).
    for line in survivingProcesses(socketPath.parentDir):
      if "runquotad" in line:
        return parseInt(line.splitWhitespace()[0])
    0

proc readToEof(job: tuple[handle: FileHandle; outPath: string]) {.thread.} =
  ## Read the verb's output to end of file from the raw handle and write it
  ## to `outPath` -- a `Process` is a ref that must not be shared with a
  ## thread, and a file keeps the text off the other thread's heap. On
  ## Windows the handle is a Win32 pipe HANDLE, not a C descriptor, so it is
  ## read as one; end of file is the pipe breaking when the last writer
  ## closes it.
  var text = ""
  var buffer: array[4096, char]
  while true:
    when defined(windows):
      var got: int32
      if readFile(Handle(job.handle), addr buffer[0], int32(buffer.len),
          addr got, nil) == 0 or got <= 0:
        break
      let n = int(got)
    else:
      let n = int(posix.read(cint(job.handle), addr buffer[0], buffer.len))
      if n <= 0:
        break
    for i in 0 ..< n:
      text.add(buffer[i])
  writeFile(job.outPath, text)

proc stopDaemon(pid: int) =
  if pid <= 0:
    return
  when defined(windows):
    let handle = openProcess(PROCESS_TERMINATE, 0, DWORD(pid))
    if handle != 0:
      discard terminateProcess(handle, 1)
      discard closeHandle(handle)
  else:
    discard execCmd("kill -9 " & $pid)

suite "runquota daemon start":
  let root = createTempDir("rq-daemon-start-", "")
  let socketPath = root / "d.sock"
  let logFile = root / "daemon.log"
  var pid = 0

  teardown:
    stopDaemon(pid)
    let deadline = epochTime() + 10
    while endpointIsBound(socketPath) and epochTime() < deadline:
      sleep(50)
    removeDir(root)

  test "returns with its output closed, and the daemon writes to its log":
    putEnv("RUNQUOTA_SOCKET", socketPath)
    defer: delEnv("RUNQUOTA_SOCKET")

    let verb = startProcess(cliPath(),
      args = ["daemon", "start", "--no-write-stats", "--log-file", logFile],
      options = {poStdErrToStdOut})
    let outputCopy = root / "verb-output.txt"
    var reader: Thread[tuple[handle: FileHandle; outPath: string]]
    createThread(reader, readToEof, (verb.outputHandle, outputCopy))

    # End of file on the verb's output within the deadline is the property:
    # with the daemon holding the verb's streams it never comes.
    proc awaitReader(seconds: int): bool =
      let until = epochTime() + float(seconds)
      while reader.running and epochTime() < until:
        sleep(50)
      not reader.running

    let closedInTime = awaitReader(60)
    # The verb returns only once the daemon answers, so the daemon is bound
    # by the time the verb has exited.
    check verb.waitForExit(10_000) == 0
    pid = daemonPid(socketPath)
    check pid > 0
    check closedInTime
    var readerDone = closedInTime
    if not readerDone:
      # Stopping the daemon closes the handle it held, which ends the read.
      stopDaemon(pid)
      readerDone = awaitReader(10)
    if not readerDone:
      # Still held: joining would hang the suite, and closing the verb's
      # handles under a read in flight blocks on Windows. Fail, and leave
      # both to process exit.
      checkpoint "the verb's output never reached end of file, even after " &
        "stopping the daemon (pid " & $pid & ")"
      fail()
    else:
      joinThread(reader)
      # Only now: closing a pipe handle while another thread has a
      # synchronous read outstanding on it blocks until that read completes.
      verb.close()
      let text = readFile(outputCopy)
      check ("runquotad log: " & logFile) in text
      # The startup lines went to the log, not to the verb's caller.
      check "runquotad listening" notin text
    check fileExists(logFile)
    check "runquotad listening" in readFile(logFile)
    check "capture disabled by --no-write-stats" in readFile(logFile)

  test "a daemon that already answers is left alone":
    putEnv("RUNQUOTA_SOCKET", socketPath)
    defer: delEnv("RUNQUOTA_SOCKET")
    let first = startProcess(cliPath(),
      args = ["daemon", "start", "--no-write-stats", "--log-file", logFile],
      options = {poStdErrToStdOut})
    discard first.waitForExit(60_000)
    first.close()
    pid = daemonPid(socketPath)
    check pid > 0

    let (output, code) = execCmdEx(quoteShell(cliPath()) &
      " daemon start --no-write-stats --log-file " & quoteShell(logFile))
    check code == 0
    check "runquotad log:" notin output
    check daemonPid(socketPath) == pid
