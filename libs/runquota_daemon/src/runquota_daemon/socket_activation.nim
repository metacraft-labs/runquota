## systemd socket activation: a `runquotad` started by a `.socket` unit serves
## the listening socket systemd hands it instead of binding one.
##
## THE PROTOCOL is
## [`sd_listen_fds(3)`](https://www.freedesktop.org/software/systemd/man/latest/sd_listen_fds.html):
## systemd passes the sockets as descriptors starting at
## `SD_LISTEN_FDS_START` (3), their number in `LISTEN_FDS`, and the pid they
## are addressed to in `LISTEN_PID`. A process whose pid is not `LISTEN_PID`
## inherited the variables from somebody else and must ignore them. This is
## that function, written out rather than linked from `libsystemd`: RunQuota
## builds on hosts without systemd, and the protocol is three variables.
##
## WHAT THE DAEMON DOES WITH IT is specified in reprobuild-pm
## `spec/RunQuota-Host-Configuration.md`, "Socket activation (systemd)":
## exactly ONE descriptor is accepted (`LISTEN_FDS` other than 1 is refused);
## it must be a listening `AF_UNIX` stream socket bound at the configured
## endpoint (`runquota_ipc.adoptListeningSocket`); the daemon never unlinks
## it, takes no lifetime lock, and never dials its own endpoint to wake its
## accept loop -- a dialled connection left queued after it exits would make
## systemd start it again at once.
##
## THE VARIABLES ARE REMOVED FROM THE DAEMON'S OWN ENVIRONMENT as soon as they
## are read, whether or not they were addressed to it, so nothing the daemon
## starts -- the `sqlite3` children of the observation store, for one --
## inherits a hand-over addressed to this process alone. Read them once, first
## thing in the entry point.
##
## WINDOWS has no socket activation; `takeSocketActivation` answers "not
## requested" there.

import std/[os, strutils]

when defined(posix):
  import std/posix
  import runquota_core/fd_hygiene

import runquota_daemon/types

const
  listenPidEnvVar* = "LISTEN_PID"
  listenFdsEnvVar* = "LISTEN_FDS"
  listenFdNamesEnvVar* = "LISTEN_FDNAMES"
  sdListenFdsStart* = 3
    ## `SD_LISTEN_FDS_START` in `<systemd/sd-daemon.h>`.
  maxHandedDescriptors = 1024
    ## A bound on how many descriptors are marked close-on-exec for a
    ## malformed `LISTEN_FDS`, so a huge value costs nothing.

proc socketActivationFrom*(listenPid, listenFds: string; hasListenPid: bool;
                           ownPid: int): SocketActivation =
  ## The decision, from the variables' values, kept pure so its table can be
  ## tested without starting a process under a forged `LISTEN_PID`.
  result = SocketActivation(requested: false, fd: -1, refusal: "")
  if not hasListenPid:
    return
  var pid = 0
  try:
    pid = parseInt(listenPid.strip())
  except ValueError:
    return
  if pid != ownPid:
    # Not addressed to this process (sd_listen_fds returns 0 here).
    return
  result.requested = true
  var count = -1
  try:
    count = parseInt(listenFds.strip())
  except ValueError:
    count = -1
  if count != 1:
    result.refusal = "runquotad: socket activation hands over " &
      (if count < 0: "an unreadable LISTEN_FDS=" & listenFds.escape
       else: "LISTEN_FDS=" & $count) &
      " descriptors; runquotad serves exactly one listening socket " &
      "(LISTEN_FDS=1). Declare one ListenStream= in the runquotad.socket unit"
    return
  result.fd = sdListenFdsStart

proc takeSocketActivation*(): SocketActivation =
  ## Reads and REMOVES `LISTEN_PID`, `LISTEN_FDS` and `LISTEN_FDNAMES`, and
  ## marks every handed descriptor close-on-exec. Call it once, first thing
  ## in the daemon's entry point.
  when defined(posix):
    let hasListenPid = existsEnv(listenPidEnvVar)
    let listenPid = getEnv(listenPidEnvVar)
    let listenFds = getEnv(listenFdsEnvVar)
    delEnv(listenPidEnvVar)
    delEnv(listenFdsEnvVar)
    delEnv(listenFdNamesEnvVar)
    result = socketActivationFrom(listenPid, listenFds, hasListenPid,
      int(getpid()))
    if result.requested:
      # CLOSE-ON-EXEC FIRST, even for a hand-over about to be refused: a
      # listener inherited by a child would keep systemd's socket open
      # after this daemon is gone.
      var count = 0
      try: count = parseInt(listenFds.strip())
      except ValueError: count = 0
      for offset in 0 ..< min(max(count, 0), maxHandedDescriptors):
        discard setCloseOnExec(cint(sdListenFdsStart + offset))
  else:
    result = SocketActivation(requested: false, fd: -1, refusal: "")
