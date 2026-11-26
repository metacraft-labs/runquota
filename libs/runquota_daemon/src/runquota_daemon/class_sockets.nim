## The daemon's class sockets: one listening socket per `[reservation.<class>]`
## table of the host file, beside the shared endpoint
## (`runquota_ipc.classEndpoint`), with the owner, group and mode the table
## declares. Who may claim a class is decided by the kernel's access check on
## its socket at `connect(2)`; a connection accepted on one carries the class
## (`runquota_daemon/class_claims`).
##
## WHAT THIS MODULE OWNS:
##
## * the PLAN: from the classes the host file declares to the socket each
##   gets, with every owner and group the daemon cannot apply refused before
##   anything is created (`planClassSockets`);
## * the REGISTRY of live class listeners, shared between the accept loop
##   (which waits on them and closes the ones a reload retired) and the
##   thread that runs a reload (which adds, drops and re-applies them). It
##   holds plain descriptors (`RawListener`), never a reference, under one
##   lock;
## * START, in two forms: binding the sockets itself (`startClassSockets`),
##   or adopting the ones systemd created under socket activation, checked
##   against the plan (`adoptClassSockets`);
## * RELOAD (`reconcileClassSockets`): a table added gets its socket, a table
##   dropped loses it (unlinked at once, closed by the accept loop), changed
##   keys are re-applied, and no connection is touched -- permissions are
##   checked at `connect(2)` only, so a reload revokes nothing. Under socket
##   activation the sockets are systemd's, so a reload that would change them
##   is refused, naming the module as the remedy.
##
## The PER-USER (private) daemon gives every class socket the private policy
## -- owner its own uid, exactly `0600`, its own group -- and ignores the
## socket keys: its directory is the user's alone, so the keys could grant
## nothing, and the client finds a class's socket the same way everywhere.
##
## Served where `runquota_protocol.ClassSocketsServed` says the daemon relies
## on the kernel's check (Linux today); elsewhere every entry point is a
## no-op and the plan is empty.

import std/[locks, strutils, tables]

import runquota_ipc
import runquota_protocol

import ./host_config

when defined(posix):
  import std/posix

type
  ClassSocketPlan* = object
    ## One class's socket, as the host file in force declares it.
    className*: string
    endpoint*: Endpoint
      ## Where it is (`classEndpoint` of the shared endpoint).
    ownerUid*: int64
      ## -1: the daemon's own uid (it creates the socket).
    groupGid*: int64
      ## The group to give it; -1 only in the private policy (left as the
      ## daemon created it).
    mode*: int

  ClassSocketProblem* = object of CatchableError
    ## A class socket the daemon cannot create as declared: an owner or
    ## group it cannot apply, a path too long. A start refused for it exits
    ## 2, like a host file whose reservations do not fit; a reload is
    ## refused with everything in force unchanged.

proc sameAccess(a, b: ClassSocketPlan): bool =
  a.ownerUid == b.ownerUid and a.groupGid == b.groupGid and a.mode == b.mode

proc accessText*(plan: ClassSocketPlan): string =
  ## `owner uid 1001, group gid 2000, mode 0660`, for messages.
  result = "mode " & classSocketModeText(plan.mode)
  if plan.ownerUid >= 0: result.add(", owner uid " & $plan.ownerUid)
  if plan.groupGid >= 0: result.add(", group gid " & $plan.groupGid)

proc planClassSockets*(reservations: OrderedTable[string, ClassReservation];
                       shared: Endpoint;
                       scope: RendezvousScope;
                       activated = false): seq[ClassSocketPlan] =
  ## The socket of every declared class, in file order. Under socket
  ## ACTIVATION (`activated`) systemd creates the sockets and applies their
  ## owner, group and mode, and the daemon only verifies them
  ## (`adoptClassSockets`), so whether this process could apply them is not
  ## asked: a daemon outside a class's `socket-group` serves the socket
  ## systemd gave that group. Otherwise it raises
  ## `ClassSocketProblem` naming the class, the socket and what is missing
  ## when one cannot be created as declared -- before anything is created.
  when ClassSocketsServed and defined(posix):
    for className, reservation in reservations:
      var endpoint: Endpoint
      try:
        endpoint = classEndpoint(shared, className)
      except ClassEndpointError as error:
        raise newException(ClassSocketProblem, "class " & className & ": " &
          error.msg)
      var plan = ClassSocketPlan(className: className, endpoint: endpoint,
        ownerUid: -1, groupGid: -1, mode: DefaultClassSocketMode)
      if scope == rendezvousPrivate:
        # THE PRIVATE POLICY, whatever the keys say: owner-only, exact.
        plan.mode = 0o600
      else:
        plan.ownerUid = reservation.socketOwnerUid
        if plan.ownerUid == int64(geteuid()):
          plan.ownerUid = -1
        # The default group is the daemon's PRIMARY group, given explicitly:
        # a socket bound in a set-group-id directory would otherwise take
        # the directory's group instead.
        plan.groupGid =
          if reservation.socketGroupGid >= 0: reservation.socketGroupGid
          else: int64(getegid())
        plan.mode =
          if reservation.socketMode != 0: reservation.socketMode
          else: DefaultClassSocketMode
        let problem =
          if activated: ""
          else: classSocketAccessProblem(ClassSocketAccess(
            ownerUid: plan.ownerUid, groupGid: plan.groupGid,
            mode: plan.mode))
        if problem.len > 0:
          raise newException(ClassSocketProblem, "class " & className &
            ": cannot create its socket " & endpoint.path & " as declared: " &
            problem)
      result.add(plan)
  else:
    discard reservations
    discard shared
    discard scope

when ClassSocketsServed and defined(posix):
  type
    ClassSocketEntry = object
      plan: ClassSocketPlan
      listener: RawListener
      adopted: bool
        ## systemd's: never changed or unlinked by this process.
      retired: bool
        ## Dropped by a reload: unlinked already, closed by the accept loop.
      dead: bool
        ## Its descriptor reported an error; no longer waited on.

  var
    registryLock: Lock
    registryReady = false
    entries: seq[ClassSocketEntry]
    activatedRegistry = false
    registryScope = rendezvousShared
    changePipe: array[2, cint] = [cint(-1), cint(-1)]
      ## Written when the set of listeners changes, so the accept loop
      ## waiting on the old set wakes and rebuilds it.

  proc toAccess(plan: ClassSocketPlan): ClassSocketAccess =
    ClassSocketAccess(ownerUid: plan.ownerUid, groupGid: plan.groupGid,
      mode: plan.mode)

  proc ensureRegistry() =
    if registryReady:
      return
    initLock(registryLock)
    var fds: array[0 .. 1, cint]
    if pipe(fds) == 0:
      for fd in fds:
        discard fcntl(fd, F_SETFD, FD_CLOEXEC)
        discard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) or O_NONBLOCK)
      changePipe = [fds[0], fds[1]]
    registryReady = true

  proc signalChange() =
    if changePipe[1] >= 0:
      var token = '\0'
      discard write(changePipe[1], addr token, 1)

proc startClassSockets*(plans: seq[ClassSocketPlan];
                        policy: RendezvousPolicy) =
  ## Bind every planned class socket, after the shared endpoint is bound.
  ## Raises `ClassSocketProblem` (exit 2) or `EndpointTrustError` (exit 3:
  ## the path is occupied by something that is not a stale socket of ours),
  ## with every socket this call bound closed and unlinked again.
  when ClassSocketsServed and defined(posix):
    ensureRegistry()
    var bound: seq[ClassSocketEntry] = @[]
    try:
      for plan in plans:
        var listener: LocalListener
        try:
          listener = bindClassSocket(plan.endpoint, plan.toAccess, policy)
        except ClassEndpointError as error:
          raise newException(ClassSocketProblem, "class " & plan.className &
            ": " & error.msg)
        except EndpointTrustError as error:
          raise newException(EndpointTrustError, "class " & plan.className &
            ": " & error.msg)
        bound.add(ClassSocketEntry(plan: plan,
          listener: rawListener(listener)))
    except CatchableError:
      for entry in bound.mitems:
        entry.listener.closeRawListener()
      raise
    acquire(registryLock)
    try:
      entries = bound
      activatedRegistry = false
      registryScope = policy.scope
    finally:
      release(registryLock)
  else:
    discard plans
    discard policy

proc adoptClassSockets*(plans: seq[ClassSocketPlan];
                        handed: seq[tuple[className: string, fd: int]];
                        policy: RendezvousPolicy) =
  ## Take the class sockets systemd created (socket activation). Every
  ## declared class must have exactly one descriptor and every descriptor a
  ## declared class; each must be listening at the class's path with exactly
  ## the declared owner, group and mode -- the module and the host file
  ## disagreeing is refused, never served. Raises `EndpointTrustError`.
  when ClassSocketsServed and defined(posix):
    ensureRegistry()
    var byName = initTable[string, int]()
    for (className, fd) in handed:
      byName[className] = fd
    for plan in plans:
      if not byName.hasKey(plan.className):
        raise newException(EndpointTrustError, "runquotad: the host file " &
          "declares class " & plan.className & " and socket activation " &
          "hands over no descriptor named " &
          classSocketPrefix & plan.className & "; declare its socket unit " &
          "(the NixOS module does, one per services.runquotad.hostConfig." &
          "reservations entry) or remove the class")
    var declared: seq[string] = @[]
    for plan in plans: declared.add(plan.className)
    for (className, _) in handed:
      if className notin declared:
        raise newException(EndpointTrustError, "runquotad: socket " &
          "activation hands over a socket for class " & className &
          ", which the host file does not declare; remove its socket unit " &
          "or declare [reservation." & className & "]")
    var adopted: seq[ClassSocketEntry] = @[]
    for plan in plans:
      let fd = byName[plan.className]
      let listener = adoptListeningSocket(cint(fd), plan.endpoint)
      let state = inspectClassSocket(plan.endpoint.path)
      let wantOwner =
        if plan.ownerUid >= 0: plan.ownerUid else: int64(geteuid())
      if not state.found or not state.isSocket or state.mode != plan.mode or
          state.ownerUid != wantOwner or
          (plan.groupGid >= 0 and state.groupGid != plan.groupGid):
        raise newException(EndpointTrustError, "runquotad: the socket of " &
          "class " & plan.className & " at " & plan.endpoint.path &
          " that socket activation handed over has " &
          (if not state.found: "no file at its path"
           else: "mode " & classSocketModeText(state.mode) & ", owner uid " &
             $state.ownerUid & ", group gid " & $state.groupGid) &
          ", and the host file declares " & accessText(plan) &
          " (owner uid " & $wantOwner & "); make the socket unit's " &
          "SocketUser, SocketGroup and SocketMode match the class's keys")
      adopted.add(ClassSocketEntry(plan: plan, listener: rawListener(listener),
        adopted: true))
    acquire(registryLock)
    try:
      entries = adopted
      activatedRegistry = true
      registryScope = policy.scope
    finally:
      release(registryLock)
  else:
    if handed.len > 0:
      raise newException(EndpointTrustError, "runquotad: socket activation " &
        "hands over class sockets, and this platform's daemon does not " &
        "serve class sockets")
    discard plans
    discard policy

proc classSocketsServing*(): bool =
  ## Whether this process serves class sockets (`startClassSockets` or
  ## `adoptClassSockets` ran). An in-process daemon (tests, embedders)
  ## that never serves an endpoint has none, and a reload then has no
  ## sockets to reconcile.
  when ClassSocketsServed and defined(posix):
    registryReady
  else:
    false

proc classSocketsAdopted*(): bool =
  ## Whether the class sockets in force are systemd's (socket activation).
  when ClassSocketsServed and defined(posix):
    if not registryReady: return false
    acquire(registryLock)
    try: activatedRegistry
    finally: release(registryLock)
  else:
    false

proc reconcileClassSockets*(plans: seq[ClassSocketPlan]) =
  ## Put a reloaded host file's class sockets in force. Raises
  ## `ClassSocketProblem` with nothing changed when they cannot be: under
  ## socket activation any change at all (the sockets are systemd's), or a
  ## new socket that cannot be bound. Changed keys are re-applied in place
  ## (`reapplyClassSocket`), so a connection accepted before the reload is
  ## kept, with its class.
  when ClassSocketsServed and defined(posix):
    if not registryReady:
      return
    acquire(registryLock)
    try:
      var current = initTable[string, int]()
      for i, entry in entries:
        if not entry.retired:
          current[entry.plan.className] = i
      var wanted = initTable[string, int]()
      for i, plan in plans:
        wanted[plan.className] = i
      if activatedRegistry:
        var changes: seq[string] = @[]
        for plan in plans:
          if not current.hasKey(plan.className):
            changes.add("adds class " & plan.className)
          elif not sameAccess(entries[current[plan.className]].plan, plan):
            changes.add("changes the socket of class " & plan.className)
        for className in current.keys:
          if not wanted.hasKey(className):
            changes.add("drops class " & className)
        if changes.len > 0:
          raise newException(ClassSocketProblem, "the reload " &
            changes.join(", ") & ", and under socket activation the class " &
            "sockets are systemd's, which this daemon never changes or " &
            "unlinks; change the reservations in the NixOS module " &
            "(services.runquotad.hostConfig.reservations) so it declares " &
            "the socket units, and restart runquotad")
        return
      # NEW SOCKETS FIRST: binding is the step that can fail, and a failure
      # here must leave the sockets in force exactly as they were.
      var added: seq[ClassSocketEntry] = @[]
      let policy = RendezvousPolicy(scope: registryScope)
      try:
        for plan in plans:
          if not current.hasKey(plan.className):
            let listener = bindClassSocket(plan.endpoint, plan.toAccess,
              policy)
            added.add(ClassSocketEntry(plan: plan,
              listener: rawListener(listener)))
      except CatchableError as error:
        for entry in added.mitems:
          entry.listener.closeRawListener()
        raise newException(ClassSocketProblem, error.msg)
      # CHANGED KEYS, re-applied in place: the socket keeps its inode and
      # every connection accepted on it. ALL OR NOTHING: what this process
      # may apply is judged for every changed socket before any is touched,
      # and a re-apply the kernel still refuses (a `chown` that fails) puts
      # back the ones already applied, so a refused reload changes no
      # socket.
      var changes: seq[tuple[index: int, after: ClassSocketPlan]] = @[]
      for plan in plans:
        if current.hasKey(plan.className):
          let index = current[plan.className]
          if not sameAccess(entries[index].plan, plan):
            let problem = classSocketAccessProblem(plan.toAccess)
            if problem.len > 0:
              for entry in added.mitems:
                entry.listener.closeRawListener()
              raise newException(ClassSocketProblem, "class " &
                plan.className & ": " & problem)
            changes.add((index: index, after: plan))
      var applied: seq[int] = @[]
      for (index, after) in changes:
        let problem = reapplyClassSocket(after.endpoint.path,
          entries[index].plan.toAccess, after.toAccess)
        if problem.len > 0:
          # The failed one may be half-applied too: restore it with the rest.
          for undo in countdown(changes.high, 0):
            let (undoIndex, undoAfter) = changes[undo]
            if undoIndex in applied or undoIndex == index:
              discard reapplyClassSocket(undoAfter.endpoint.path,
                undoAfter.toAccess, entries[undoIndex].plan.toAccess)
          for entry in added.mitems:
            entry.listener.closeRawListener()
          raise newException(ClassSocketProblem, "class " &
            after.className & ": " & problem &
            "; the class sockets in force are unchanged")
        applied.add(index)
      for (index, after) in changes:
        entries[index].plan = after
      # DROPPED TABLES lose their socket now: the name goes at once, so no
      # new connection reaches it, and the accept loop closes the
      # descriptor when it next wakes. Connections already accepted on it
      # are not touched and keep their class.
      var changed = added.len > 0
      for i in 0 ..< entries.len:
        if not entries[i].retired and
            not wanted.hasKey(entries[i].plan.className):
          entries[i].listener.unlinkRawListener()
          entries[i].retired = true
          changed = true
      for entry in added:
        entries.add(entry)
      if changed:
        signalChange()
    finally:
      release(registryLock)
  else:
    discard plans

proc classSocketChangeFd*(): cint =
  ## The read end of the pipe a reload writes when the listeners change, or
  ## -1. The accept loop waits on it beside the listeners.
  when ClassSocketsServed and defined(posix):
    if registryReady: changePipe[0] else: cint(-1)
  else:
    cint(-1)

proc liveClassListeners*(): seq[tuple[className: string, fd: cint]] =
  ## The class listeners to wait on now. Also CLOSES the ones a reload
  ## retired and drains the change pipe: called only by the accept loop,
  ## which is therefore the one thread that closes a descriptor it might be
  ## waiting on.
  when ClassSocketsServed and defined(posix):
    if not registryReady:
      return
    var token: array[64, char]
    if changePipe[0] >= 0:
      while read(changePipe[0], addr token[0], token.len) > 0:
        discard
    acquire(registryLock)
    try:
      var kept: seq[ClassSocketEntry] = @[]
      for entry in entries.mitems:
        if entry.retired:
          entry.listener.closeRawListener()
        else:
          kept.add(entry)
          if not entry.dead:
            result.add((className: entry.plan.className,
              fd: entry.listener.fd))
      entries = kept
    finally:
      release(registryLock)

proc acceptOnClassSocket*(fd: cint): AcceptedConnection =
  ## Accept one connection on the class listener `fd`. Raises `OSError`.
  when ClassSocketsServed and defined(posix):
    acceptRaw(RawListener(fd: fd))
  else:
    discard fd
    raise newException(OSError, "class sockets are not served here")

proc markClassListenerDead*(fd: cint; reason: string): string =
  ## Stop waiting on a class listener whose descriptor reports an error, so
  ## the accept loop does not spin on it; returns the line to log.
  when ClassSocketsServed and defined(posix):
    acquire(registryLock)
    try:
      for entry in entries.mitems:
        if entry.listener.fd == fd and not entry.dead:
          entry.dead = true
          return "runquotad: the socket of class " & entry.plan.className &
            " stopped accepting (" & reason & "); its class can be " &
            "claimed again after a restart"
    finally:
      release(registryLock)
    ""
  else:
    discard fd
    discard reason
    ""

proc stopClassSockets*() =
  ## Close every class listener, unlinking the ones this process created.
  ## On every path out of `serve`; idempotent.
  when ClassSocketsServed and defined(posix):
    if not registryReady:
      return
    acquire(registryLock)
    try:
      for entry in entries.mitems:
        if entry.adopted:
          # systemd's: closed, never unlinked.
          entry.listener.boundInode = 0
        entry.listener.closeRawListener()
      entries = @[]
    finally:
      release(registryLock)

proc classSocketReport*(): string =
  ## ` (class sockets: ci 0660 at /run/runquota/class-ci.sock, ...)`, for
  ## the daemon's listening line; empty when there are none.
  when ClassSocketsServed and defined(posix):
    if not registryReady:
      return ""
    var parts: seq[string] = @[]
    acquire(registryLock)
    try:
      for entry in entries:
        if not entry.retired:
          parts.add(entry.plan.className & " " &
            classSocketModeText(entry.plan.mode) & " at " &
            entry.plan.endpoint.path)
    finally:
      release(registryLock)
    if parts.len == 0: "" else: " (class sockets: " & parts.join(", ") & ")"
  else:
    ""

proc declaredClassNames*(reservations: OrderedTable[string,
                         ClassReservation]): seq[string] =
  for name in reservations.keys:
    result.add(name)

