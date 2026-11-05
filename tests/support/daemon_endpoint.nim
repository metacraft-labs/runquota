## "Is the daemon listening yet?", asked the same way on every platform.
##
## Every integration test that starts a real ``runquotad`` with
## ``--socket <path>`` waits for the endpoint to appear before it connects.
## Each file used to carry its own ``socketIsBound`` built on ``lstat`` and
## ``S_ISSOCK``, which is the POSIX answer and does not compile on Windows --
## where the same ``--socket`` argument names a NAMED PIPE, mapped onto
## ``\\.\pipe\runquota-<token>`` by ``runquota_ipc.endpointForPath``, and
## there is no file to ``lstat`` at all.
##
## This asks the question in terms of the endpoint the daemon really binds:
## on POSIX, a socket inode at the path; on Windows, a pipe of the mapped
## name, probed with ``WaitNamedPipeW`` so that no pipe instance is consumed
## by asking.

import std/[osproc, streams, strutils]

import runquota_ipc
import runquota_process

when defined(windows):
  import std/[oserrors, winlean]

  proc waitNamedPipeW(name: WideCString; timeoutMillis: int32): WINBOOL
    {.stdcall, dynlib: "kernel32.dll", importc: "WaitNamedPipeW".}

  const
    ErrorFileNotFound = 2'i32

  proc endpointIsBound*(socketPath: string): bool =
    ## True once a pipe of the name ``socketPath`` maps to exists. A pipe
    ## whose every instance is busy still EXISTS -- ``WaitNamedPipeW`` then
    ## times out rather than reporting it missing -- so only "file not
    ## found" means "not bound yet".
    let pipeName = endpointForPath(socketPath).path
    if waitNamedPipeW(newWideCString(pipeName), 1'i32) != 0:
      return true
    osLastError().int32 != ErrorFileNotFound
else:
  import std/posix

  proc endpointIsBound*(socketPath: string): bool =
    ## True once a socket inode exists at ``socketPath``. ``lstat``, so a
    ## symlink planted there is not mistaken for the daemon's socket.
    var info: Stat
    lstat(socketPath.cstring, info) == 0 and S_ISSOCK(info.st_mode)

proc readStartupLines[P](output: Stream; process: var P; count: Positive;
                         context: string): seq[string] =
  ## Only real streams and real nonblocking process-status operations enter
  ## this loop. Each launcher retains its own descriptor/handle ownership.
  for _ in 0 ..< count:
    try:
      result.add(output.readLine())
    except IOError as error:
      when P is Process:
        let status = osproc.peekExitCode(process)
      elif P is LaunchedProcess:
        let status =
          if runquota_process.pollCompletion(process): process.completion.exitCode
          else: -1
      else:
        {.error: "startup reader requires an actual supported process handle".}
      raise newException(IOError, context & ": startup output ended after " &
        $result.len & " of " & $count & " required lines; child exit=" &
        $status & "; original error: " & error.msg &
        "\nactual startup prefix:\n" & result.join("\n"))

proc readRequiredStartupLines*(process: Process; count: Positive;
                               context: string): seq[string] =
  ## Preserve the existing std/osproc startup protocol and exact line count.
  var actual = process
  readStartupLines(process.outputStream, actual, count, context)

proc readRequiredStartupLines*(process: var LaunchedProcess; output: Stream;
                               count: Positive; context: string): seq[string] =
  ## `output` owns the real pipe detached from this launcher's capture state;
  ## pollCompletion must not drain or close that same descriptor a second time.
  readStartupLines(output, process, count, context)
