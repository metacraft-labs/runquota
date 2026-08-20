## The machine's own ``host_id``: stable, opaque, and owned by the machine
## rather than by any one database.
##
## Normative specification:
## ``reprobuild-specs/RunQuota-Observation-Store.md`` §"`hosts` and
## `host_profiles`" — "`host_id` MUST NOT be a hostname. Hostnames are
## renamed and reused, which silently merges the histories of unrelated
## machines."
##
## The negative is the whole design, so it is worth saying what it rules
## out. Any *derivation* from the hostname has the defect, not just the
## literal name: two machines both called ``build01`` produce the same id
## under a hash of the name just as surely as under the name itself, and a
## merged database then reports one machine's durations as the other's.
## The same objection applies to a MAC address, a serial number or an IP.
## So nothing about the machine is an input here at all. The id is 128
## random bits minted once and written to a file, and its only property is
## that no other machine has it.
##
## The consequence, stated plainly: identity lives in that file. Delete it
## and the machine becomes a new machine, its history intact but no longer
## attached to it. That is the correct failure — a lost identity splits a
## history, where a hostname-derived one merges two, and a split is
## visible in the data while a merge is not.

import std/[os, strutils]

import ./ids

type
  HostIdentity* = object
    hostId*: string
      ## Empty only if no identity could be produced at all.
    path*: string
    persisted*: bool
      ## False when the id could not be written down, and so will not
      ## survive this process. The caller reports it; capture continues.
    report*: string

const hostIdPrefix* = "host-"

proc defaultHostIdentityFile*(): string =
  ## Per-user, per-machine, outside any database directory. A store is a
  ## file that gets copied, merged and thrown away; the machine's identity
  ## must not travel with one.
  when defined(windows):
    let base = getEnv("LOCALAPPDATA")
    let root = if base.len > 0: base else: getHomeDir()
    root / "runquota" / "host-id"
  else:
    let xdg = getEnv("XDG_STATE_HOME")
    let root = if xdg.len > 0: xdg else: getHomeDir() / ".local" / "state"
    root / "runquota" / "host-id"

proc resolveHostIdentity*(path = ""): HostIdentity =
  ## Reads the machine's ``host_id``, minting and persisting one on first
  ## use. Never raises.
  let file = if path.len > 0: path else: defaultHostIdentityFile()
  result = HostIdentity(hostId: "", path: file, persisted: false, report: "")

  if fileExists(file):
    var existing = ""
    try:
      existing = readFile(file).strip()
    except CatchableError as error:
      existing = ""
      result.report = "runquota host identity " & file & ": unreadable (" &
        error.msg & ")"
    if isOpaqueId(existing, hostIdPrefix):
      result.hostId = existing
      result.persisted = true
      result.report = "runquota host identity " & file & ": " & existing
      return
    if existing.len > 0:
      # A file that is not an identity is not overwritten. Whatever it is,
      # something else owns it, and clobbering it to make this start tidy
      # would be the daemon deciding it knows better.
      result.hostId = opaqueId(hostIdPrefix)
      result.report = "runquota host identity " & file &
        ": file does not hold a RunQuota host id and was left alone; " &
        "using a temporary identity that will not survive a restart"
      return

  result.hostId = opaqueId(hostIdPrefix)
  try:
    let parent = file.parentDir
    if parent.len > 0 and not dirExists(parent):
      createDir(parent)
    # Write-then-rename: a torn write would leave a file that fails
    # `isOpaqueId` and mint a second identity for one machine on the next
    # start, which is exactly the accumulation this is here to prevent.
    let temporary = file & ".new." & $getCurrentProcessId()
    writeFile(temporary, result.hostId & "\n")
    moveFile(temporary, file)
    result.persisted = true
    result.report = "runquota host identity " & file & ": created " &
      result.hostId
  except CatchableError as error:
    result.report = "runquota host identity " & file & ": cannot persist (" &
      error.msg & "); using a temporary identity that will not survive a " &
      "restart"
