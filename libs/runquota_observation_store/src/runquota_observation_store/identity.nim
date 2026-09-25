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
##
## AN IDENTITY THAT CANNOT BE PERSISTED IS A REFUSAL, NEVER AN EPHEMERAL
## ONE. This is the other half of "minted *once*", and it is the rule that
## closes a whole class of silent degradation. Minting an id that is not
## written down satisfies every type in the system and has no symptom at
## the point of use: each invocation becomes a new machine, no two rows
## ever pool, and the aggregates still carry *a* hardware dimension, so
## nothing looks wrong. That is strictly worse than the per-user file this
## replaced, which at least persisted. So every failure below returns an
## EMPTY ``hostId`` with a report naming the path and the reason, and the
## daemon turns capture off rather than recording against a fiction.
##
## Specified in ``reprobuild-specs/RunQuota-Observation-Store.md``
## §"The Execution Spine": "**A `host_id` that cannot be persisted MUST be
## a refusal, never an ephemeral one.**"

import std/[os, strutils]

when not defined(windows):
  import std/posix
else:
  import runquota_host_windows/security

import ./ids

type
  HostIdentity* = object
    hostId*: string
      ## The machine's identity, or EMPTY. Non-empty IF AND ONLY IF
      ## ``persisted`` is true — an id nothing wrote down is not an
      ## identity, because the next process would mint a different one.
      ## Callers key capture off this being non-empty.
    path*: string
    persisted*: bool
      ## True only when ``hostId`` was read back from ``path`` or written
      ## to it. False means REFUSED: there is no id, and ``report`` says
      ## which path and why.
    report*: string
      ## ONE LINE, always. The daemon prints this as one of a fixed number
      ## of startup lines, and a reader that has to guess how many lines it
      ## will get is a reader that deadlocks. ``OSError.msg`` embeds a
      ## newline on macOS ("Additional info: ..."), so it is folded.

const hostIdPrefix* = "host-"

const
  hostIdentityFileName = "host-id"
  observationDbFileName* = "observations.sqlite3"
    ## The default store file, kept in the SAME host-wide directory as the
    ## identity file. Both are host state, both are daemon-owned, and both
    ## are provisioned by the same install step, so an operator who has to
    ## relocate one has to relocate the other — one decision rather than
    ## two paths that can silently disagree.
    ##
    ## This does NOT put the identity inside a database *directory*, which
    ## is what the module comment above forbids: the store is one file
    ## beside the identity file, so copying, merging or discarding a store
    ## never carries the machine's identity with it.
  # HOST-WIDE AND DAEMON-OWNED, not per-user.
  #
  # `runquotad` is one daemon per host, so `host_id` identifies the MACHINE
  # and its state file has to be as host-wide as the daemon that owns it.
  # Minting it per user -- under `XDG_STATE_HOME`, as this did before --
  # makes one machine present as several, and that defeats OS-6 in the
  # direction hardest to notice: the aggregates still carry *a* hardware
  # dimension, so nothing looks wrong, but the durations from one host are
  # split across several identities and never pool. A CI box where a dozen
  # accounts build the same tree -- the machine with the most history to
  # pool -- is where it costs the most.
  #
  # Nothing per-user may appear in this path. `HOME`, `XDG_STATE_HOME` and
  # `LOCALAPPDATA` all differ between two users on one machine, which is
  # exactly the property that must not be here.
  #
  # THESE THREE PATHS ARE ALSO WRITTEN DOWN IN `nix/host-state.nix`, which
  # is what the install step provisions from. The two must agree, and
  # `tests/integration/t_host_identity_refusal.nim` asserts that they do:
  # a directory provisioned somewhere the daemon does not look is the same
  # unprovisioned host with more moving parts.
  hostWideStateDir* =
    when defined(windows):
      r"C:\ProgramData\runquota"
    elif defined(macosx):
      "/var/db/runquota"
    else:
      "/var/lib/runquota"

proc oneLine(text: string): string =
  ## Folds an embedded newline. `OSError.msg` on macOS is two lines --
  ## the message and an "Additional info:" line -- and the daemon's
  ## startup output is a FIXED number of lines that a test reads by
  ## count. An unfolded message silently adds a fourth line and every
  ## reader of the third one deadlocks or misreads.
  var parts: seq[string] = @[]
  for line in text.splitLines:
    let trimmed = line.strip()
    if trimmed.len > 0:
      parts.add(trimmed)
  parts.join("; ")

when defined(windows):
  proc restrictHostStateDirCommand*(directory: string; account = ""): string =
    ## WINDOWS: the ``icacls`` line that gives ``directory`` the DACL the
    ## daemon's trust check accepts. The Windows counterpart of the POSIX
    ## ``chown`` + ``chmod 0755``, and like them it names the DAEMON's
    ## account, not the operator's.
    ##
    ## ``/inheritance:r`` IS THE POINT. ``C:\ProgramData`` hands every
    ## directory created under it ``BUILTIN\Users:(CI)(WD,AD,WEA,WA)`` --
    ## any user may add files and subdirectories -- so a bare ``mkdir``
    ## there makes a state directory in which another user can plant
    ## ``host-id`` or ``observations.sqlite3`` before the daemon does.
    ## Removing inheritance drops that, and the grants put back exactly
    ## what the POSIX ``0755`` means: full control for the daemon's
    ## account, SYSTEM and Administrators, and read/traverse for every
    ## user.
    ##
    ## ``/reset`` FIRST, as its own command, because the refusal this is
    ## printed in can be about an EXPLICIT ACE, and ``/grant:r`` does not
    ## remove one: it replaces a principal's grant only for the same
    ## inheritance flags, so ``Users:(CI)(WD,AD,...)`` survives a
    ## ``/grant:r Users:(OI)(CI)RX`` untouched -- measured, and the reason
    ## the repair once left the directory refused. ``/reset`` drops every
    ## explicit ACE, whoever wrote it; ``/inheritance:r`` then drops the
    ## inherited ones; the grants are then the whole DACL. On a directory
    ## ``mkdir`` has just made it is a no-op.
    ##
    ## ``account`` is how the command names the daemon's account. Empty --
    ## what the daemon itself prints -- means THIS process's own SID, filled
    ## in the way the POSIX command fills in ``getuid()``; the runbook,
    ## which cannot know it, passes ``%USERDOMAIN%\%USERNAME%`` for cmd.exe
    ## to expand as whoever runs it. A daemon running as SYSTEM or as
    ## Administrators gets no separate grant: the first two already say it.
    let sid = (if account.len > 0: "" else: processUserSid())
    let who =
      if account.len > 0: account
      elif sid.len > 0: "*" & sid
      else: r"%USERDOMAIN%\%USERNAME%"
    result = "icacls \"" & directory & "\" /reset && icacls \"" &
      directory & "\" /inheritance:r /grant:r " &
      "\"*S-1-5-18:(OI)(CI)F\" \"*S-1-5-32-544:(OI)(CI)F\" "
    if sid notin ["S-1-5-18", "S-1-5-32-544"]:
      result.add("\"" & who & ":(OI)(CI)F\" ")
    result.add("\"*S-1-5-32-545:(OI)(CI)RX\"")

proc provisionHostStateDirCommand*(directory: string; account = ""): string =
  ## The exact command an operator runs on a host the install step has not
  ## reached. Named in the refusal itself: a refusal that says only "cannot
  ## persist" leaves the operator to guess, and the guess -- creating the
  ## directory as whoever happens to be logged in -- is the failure this
  ## whole rule exists to prevent.
  ##
  ## Ownership is the DAEMON's, not root's: the daemon has to write the
  ## identity file inside it on first start. The mode is 0755 rather than
  ## 0700 because the directory is host-wide by design.
  ##
  ## On Windows a bare ``mkdir`` is NOT enough, and used to be all this
  ## printed: see ``restrictHostStateDirCommand``, whose ``icacls`` follows
  ## it. ``account`` is passed through to it, and ignored on POSIX, where
  ## the uid is always this process's own.
  when defined(windows):
    "mkdir \"" & directory & "\" && " &
      restrictHostStateDirCommand(directory, account)
  else:
    discard account
    "sudo mkdir -p " & directory & " && sudo chown " & $getuid() & " " &
      directory & " && sudo chmod 0755 " & directory

proc defaultHostIdentityFile*(): string =
  ## The machine's identity file. Host-wide, daemon-owned, and outside any
  ## database directory: a store is a file that gets copied, merged and
  ## thrown away, and the machine's identity must not travel with one.
  ##
  ## Deliberately reads no environment at all. An env-var override would
  ## reintroduce, per user, precisely the divergence this constant exists
  ## to remove; an operator who needs a different path passes one
  ## explicitly (``--host-identity-file``), which is a decision the host
  ## makes once rather than one each session inherits.
  hostWideStateDir / hostIdentityFileName

proc observationDbBeside*(hostIdentityFile: string): string =
  ## The store that belongs to the host state named by ``hostIdentityFile``.
  ##
  ## CAPTURE IS ON BY DEFAULT (the specification's §"Capture Is Enabled By
  ## Default"), so the daemon needs a store path when nobody gave it one,
  ## and this is that path. It is derived from the identity file rather
  ## than being a second constant because the two must never disagree: an
  ## operator who moves the host state with ``--host-identity-file`` moves
  ## the store with it, and a store recording rows against a ``host_id``
  ## kept somewhere else is a store nobody can interpret.
  ##
  ## Reads no environment, for the reason ``defaultHostIdentityFile``
  ## gives: a per-user override reintroduces per-user divergence into
  ## host-wide state.
  let file =
    if hostIdentityFile.len > 0: hostIdentityFile else: defaultHostIdentityFile()
  let directory = file.parentDir
  if directory.len == 0:
    return observationDbFileName
  directory / observationDbFileName

proc defaultObservationDbFile*(): string =
  ## The store this host uses when no path was configured.
  observationDbBeside(defaultHostIdentityFile())

proc resolveHostIdentity*(path = ""): HostIdentity =
  ## Reads the machine's ``host_id``, minting and persisting one on first
  ## use inside an ALREADY-PROVISIONED directory. Never raises.
  ##
  ## EVERY FAILURE IS A REFUSAL: ``hostId`` comes back empty, ``persisted``
  ## false, and ``report`` names the path and the reason. Nothing here ever
  ## returns an id that is not on disk. The result satisfies, on every
  ## path, ``(hostId.len > 0) == persisted``.
  ##
  ## The result is also a FUNCTION OF THE FILESYSTEM AND NOTHING ELSE, so
  ## two consecutive calls agree. That is the only property that separates
  ## a real identity from a fresh one that looks fine, and it is what the
  ## suite's repetition control asserts.
  let file = if path.len > 0: path else: defaultHostIdentityFile()
  let directory = file.parentDir
  result = HostIdentity(hostId: "", path: file, persisted: false, report: "")

  if fileExists(file):
    var existing = ""
    try:
      existing = readFile(file).strip()
    except CatchableError as error:
      result.report = "runquota host identity " & file &
        ": cannot persist -- unreadable (" & oneLine(error.msg) &
        "); no identity was minted and capture stays off"
      return
    if isOpaqueId(existing, hostIdPrefix):
      result.hostId = existing
      result.persisted = true
      result.report = "runquota host identity " & file & ": " & existing
      return
    if existing.len > 0:
      # A file that is not an identity is not overwritten. Whatever it is,
      # something else owns it, and clobbering it to make this start tidy
      # would be the daemon deciding it knows better.
      result.report = "runquota host identity " & file &
        ": cannot persist -- the file does not hold a RunQuota host id and " &
        "was left alone; no identity was minted and capture stays off"
      return

  # THE DIRECTORY IS PROVISIONED BY THE INSTALL STEP AND IS NOT CREATED
  # HERE. `createDir` used to be on this line, and it is the reason the
  # host-wide move made things worse rather than better: `/var/db` and
  # `/var/lib` are root-owned 0755, so an unprivileged daemon's `createDir`
  # always failed and the old code answered by minting an id per process.
  # Creating it when the daemon *can* is not the fix either -- a path any
  # caller can create is a path any caller can create DIFFERENTLY, with
  # whatever owner and mode the first starter happened to have. So the
  # directory's owner and mode are decided once, by installation, and a
  # missing one is reported with the command that creates it.
  if directory.len > 0 and not dirExists(directory):
    result.report = "runquota host identity " & file &
      ": cannot persist -- the host-wide state directory " & directory &
      " does not exist. It is created by the RunQuota install step, never " &
      "by the daemon; provision it with: " &
      provisionHostStateDirCommand(directory) &
      " -- no identity was minted and capture stays off"
    return

  # Write-then-rename: a torn write would leave a file that fails
  # `isOpaqueId` and mint a second identity for one machine on the next
  # start, which is exactly the accumulation this is here to prevent.
  #
  # The id is assigned to `result` only after the rename lands. An id that
  # exists in this process and nowhere else is precisely what must not
  # escape from here.
  let minted = opaqueId(hostIdPrefix)
  let temporary = file & ".new." & $getCurrentProcessId()
  try:
    writeFile(temporary, minted & "\n")
    moveFile(temporary, file)
    result.hostId = minted
    result.persisted = true
    result.report = "runquota host identity " & file & ": created " & minted
  except CatchableError as error:
    # A write that landed but did not get renamed leaves a stray file in a
    # host-wide directory, and the next start would leave another. Removed
    # best-effort: failing to clean up must not turn a refusal into a
    # raise, since callers are promised this never raises.
    try:
      if fileExists(temporary):
        removeFile(temporary)
    except CatchableError:
      discard
    result.report = "runquota host identity " & file &
      ": cannot persist -- " & oneLine(error.msg) & " (state directory " &
      directory & "); no identity was minted and capture stays off"
