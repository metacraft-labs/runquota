import std/osproc

import runquota_process/types

export types

const libraryName* = "runquota_process"

proc libraryInfo*(): LibraryInfo =
  LibraryInfo(name: libraryName)

proc launchResult*(processId: uint64; running: bool): LaunchResult =
  LaunchResult(processId: processId, running: running)

proc launchProcess*(program: string; args: openArray[string] = []): LaunchedProcess =
  let child = startProcess(program, args = @args, options = {poStdErrToStdOut})
  LaunchedProcess(
    handle: child,
    info: launchResult(uint64(child.processID), child.running)
  )

proc waitForExit*(child: var LaunchedProcess; timeout = -1): int =
  child.handle.waitForExit(timeout)

proc terminate*(child: var LaunchedProcess) =
  child.handle.terminate()

proc close*(child: var LaunchedProcess) =
  child.handle.close()

proc running*(child: LaunchedProcess): bool =
  child.handle.running
