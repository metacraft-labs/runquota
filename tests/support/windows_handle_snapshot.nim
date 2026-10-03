## Read-only Windows PSS diagnostics. No mocks or cloned process memory.
## The real named-event control is in the connection-failure integration test.
import std/[os, winlean]

when not defined(windows):
  {.error: "Windows process snapshots require Windows".}

{.compile: "windows_handle_snapshot.c".}

proc writeSnapshot(pid: cuint; path: WideCString): cint
  {.cdecl, importc: "rq_write_windows_handle_snapshot".}

proc captureWindowsHandles*(pid: int; path: string): string =
  let code = writeSnapshot(cuint(pid), newWideCString(path))
  result = if fileExists(path): readFile(path) else: "no snapshot was written"
  if code != 0:
    raise newException(IOError, "Windows handle snapshot failed: " & result)
