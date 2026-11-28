## Read-only process introspection for the nix build hook's integration
## tests: a process's live children, its argument vector and its
## environment, on Linux (`/proc`) and darwin (`libproc` and
## `KERN_PROCARGS2`, through the hook's own darwin module, so the tests read
## processes the way the hook does). Nothing here signals or opens a
## process; a process that is gone, or not this user's, reads as empty.

import std/[os, strutils]

when defined(macosx):
  import runquota_cli_support/nix_hook
  import runquota_cli_support/nix_hook_darwin

proc childrenOf*(pid: int): seq[int] =
  ## The live (not zombie) children of `pid`.
  when defined(linux):
    for kind, dir in walkDir("/proc"):
      let name = extractFilename(dir)
      if name.len == 0 or not name[0].isDigit: continue
      try:
        let stat = readFile(dir / "stat")
        let fields = stat[stat.rfind(')') + 2 .. ^1].splitWhitespace()
        if fields.len > 1 and fields[0] != "Z" and parseInt(fields[1]) == pid:
          result.add(parseInt(name))
      except CatchableError:
        discard
  elif defined(macosx):
    # A zombie has no task, so its identity cannot be read: it is skipped.
    for candidate in allPids():
      var identity: ProcessIdentity
      if processIdentity(candidate, identity) and identity.ppid == pid:
        result.add(candidate)

proc processArgv*(pid: int): seq[string] =
  when defined(linux):
    try:
      for arg in readFile("/proc" / $pid / "cmdline").split('\0'):
        if arg.len > 0: result.add(arg)
    except CatchableError:
      discard
  elif defined(macosx):
    try: result = parseProcArgs2(procArgs(pid, 4 * 1024 * 1024)).argv
    except CatchableError: discard

proc processEnviron*(pid: int): seq[string] =
  ## `NAME=value` entries of `pid`'s environment as it was exec'd.
  when defined(linux):
    try:
      for entry in readFile("/proc" / $pid / "environ").split('\0'):
        if entry.len > 0: result.add(entry)
    except CatchableError:
      discard
  elif defined(macosx):
    try: result = parseProcArgs2(procArgs(pid, 4 * 1024 * 1024)).env
    except CatchableError: discard

proc allProcesses*(): seq[int] =
  when defined(linux):
    for kind, dir in walkDir("/proc"):
      let name = extractFilename(dir)
      if name.len > 0 and name[0].isDigit:
        try: result.add(parseInt(name))
        except ValueError: discard
  elif defined(macosx):
    result = allPids()

proc holdersOf*(rqSocket: string): seq[int] =
  ## Nix build hook lease holders still running for a test's private
  ## `runquotad`: processes whose command line is a holder's and whose
  ## environment names that daemon's socket. On darwin a holder is two
  ## processes (the watcher and its lease holder); both count.
  let marker = "RUNQUOTA_SOCKET=" & rqSocket
  for pid in allProcesses():
    if "--hold" notin processArgv(pid): continue
    if marker in processEnviron(pid): result.add(pid)

proc noHoldersLeft*(rqSocket: string; waitMillis = 4000): bool =
  ## A holder gives its lease back and exits at most ~400 ms after its
  ## build's locks go free.
  let deadline = waitMillis div 100
  for _ in 0 ..< max(1, deadline):
    if holdersOf(rqSocket).len == 0: return true
    sleep(100)
  false
