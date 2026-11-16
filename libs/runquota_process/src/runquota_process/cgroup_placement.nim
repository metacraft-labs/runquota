## Where a leased process tree runs below admission: the Linux cgroup v2
## placement of RunQuota's launchers, and the nice values that stand in for
## it where it is not available.
##
## WHY BELOW ADMISSION. Admission decides how much CPU a tree is GRANTED; it
## cannot stop a tool that ignores its grant and starts one process per core.
## Placing each tree in a cgroup of its session group, whose `cpu.weight`
## follows the group's priority, makes such a tool compete at its group's
## priority, and work admitted into predicted slack (a reclaimed grant) runs
## in a subtree of the lowest weight, so it yields to everything it was
## admitted beside. The kernel's CPU controller (cgroup v2 `cpu.weight`,
## `cpu.max`) is documented at
## https://docs.kernel.org/admin-guide/cgroup-v2.html#cpu-interface-files
##
## THE LAYOUT, under a root resolved per user (`resolveCgroupRoot`):
##
##   <root>/                      cgroup.subtree_control += cpu
##     group-<escaped name>/      cpu.weight from the group's priority
##       shared/                  every uncapped tree of the group
##       cap-<pid>-<n>/           one capped tree, cpu.max = its grant
##     reclaimed/                 cpu.weight 1
##       shared/, cap-<pid>-<n>/
##
## Processes live only in leaves: cgroup v2 forbids processes in a cgroup
## that enables a controller for its children ("no internal process"
## constraint, same document, § "No Internal Process Constraint").
##
## WHO CREATES IT. The launching client, never `runquotad` (which does not
## spawn or contain process trees). The default root is the caller's own
## systemd-delegated user subtree, so each user's trees are in that user's
## cgroups and nothing here needs privilege. systemd's delegation rules:
## https://systemd.io/CGROUP_DELEGATION/
##
## NOTHING HERE MAY FAIL A LAUNCH. Every problem becomes a reason string the
## launcher reports and the capability record carries, and the tree runs
## with the nice fallback (`fallbackNice`).
##
## Static-helper library rules apply (no `ref` types): this module is part of
## `runquota_process`.

import std/[os, strutils]
when defined(posix):
  import std/posix

import runquota_core
import runquota_core/sha256

const
  CgroupRootEnvVar* = "RUNQUOTA_CGROUP_ROOT"
    ## Unset or empty: what the host file says (`[enforcement] cgroups`,
    ## off when absent), at the default root. `off`: no placement, whatever
    ## the host file says. Otherwise an absolute path inside the cgroup v2
    ## mount: placement ON under that root (an explicit opt-in, for tests,
    ## the overhead gate and hosts that delegate another subtree).
  CgroupRootOff* = "off"
  CgroupMountPoint* = "/sys/fs/cgroup"
  DefaultRootName* = "runquota.slice"
  GroupDirPrefix* = "group-"
    ## Keeps a group named `reclaimed` apart from the reclaimed subtree, and
    ## every group directory name away from the kernel's interface files
    ## (`cpu.weight`, `cgroup.procs`, ...), which all contain a `.` that the
    ## escaping below never leaves in a name anyway.
  ReclaimedDirName* = "reclaimed"
  SharedLeafName* = "shared"
  CapLeafPrefix* = "cap-"
  ReclaimedCpuWeight* = 1
    ## The kernel's minimum weight: a reclaimed tree yields to every placed
    ## group and to unplaced work alike.
  CpuMaxPeriodMicros* = 100_000
    ## The kernel's default `cpu.max` period (100 ms).
  MinCpuMaxQuotaMicros* = 1_000
    ## The smallest quota the kernel accepts (1 ms).
  MaxEscapedNameBytes* = 200
  KeptEscapedNameBytes* = 160
  NameHashHexDigits* = 16
  ReclaimedNiceIncrement* = 10
    ## How much lower a RECLAIMED grant's tree runs (nice +10: a weight of
    ## about a tenth of a nice-0 task under Linux's CFS/EEVDF weights), with
    ## or without its cgroup. In the cgroup it also yields inside its leaf;
    ## without it, it is the whole of the lower weight.
  LowPriorityNiceIncrement* = 5
    ## Where placement is unavailable, a tree of a `low` group runs at nice
    ## +5 (about a third of a nice-0 task's weight). The other priorities
    ## get no nice: raising a priority needs privilege.
  PlacementAttempts* = 3
    ## How often a launch prepares its leaf and tries to start the child in
    ## it, when another launcher's clean-up removed the leaf in between.

type
  CgroupRootState* = enum
    crsDefault = "default"
      ## `runquota.slice` below the caller's own `user@<uid>.service`.
    crsExplicit = "explicit"
      ## Named by `RUNQUOTA_CGROUP_ROOT`.
    crsOff = "off"
      ## Turned off: by `RUNQUOTA_CGROUP_ROOT=off`, or by default (the host
      ## file does not turn `[enforcement] cgroups` on).
    crsUnavailable = "unavailable"
      ## No root could be resolved; `reason` says why.

  CgroupRoot* = object
    state*: CgroupRootState
    path*: string
      ## The root directory, for `crsDefault` and `crsExplicit`.
    reason*: string
      ## Why there is no root, for `crsOff` and `crsUnavailable`.

  CgroupTarget* = object
    ## Where one launch puts its tree: plain data, so that a launcher that
    ## must prepare the directories again (another launcher removed them)
    ## can do so without calling back into whoever chose the group.
    root*: string
      ## "" means no placement.
    dirName*: string
      ## `group-<escaped>` or `reclaimed`.
    cpuWeight*: int
      ## Written to `<root>/<dirName>/cpu.weight` each time it is prepared.
    leafName*: string
      ## `shared` or `cap-<pid>-<n>`.
    cpuMax*: string
      ## "" for an uncapped leaf; otherwise the `cpu.max` text of a cap leaf.

proc placed*(target: CgroupTarget): bool =
  ## Whether `target` asks for any placement at all.
  target.root.len > 0

proc dirPath*(target: CgroupTarget): string =
  target.root / target.dirName

proc leafPath*(target: CgroupTarget): string =
  target.root / target.dirName / target.leafName

proc isCapLeaf*(target: CgroupTarget): bool =
  target.leafName.startsWith(CapLeafPrefix)

# ---------------------------------------------------------------------------
# Pure rules
# ---------------------------------------------------------------------------

proc cpuWeightFor*(priority: SessionPriority): int =
  ## `cpu.weight` of a session group's cgroup. Each level gets four times the
  ## CPU of the one below when both are busy; `normal` is the kernel's
  ## default weight (100), so a normal group competes evenly with work that
  ## RunQuota does not place.
  case priority
  of sessionPriorityLow: 25
  of sessionPriorityNormal: 100
  of sessionPriorityHigh: 400
  of sessionPriorityUrgent: 1600

proc fallbackNice*(priority: SessionPriority; reclaimed: bool): int =
  ## The nice increment a tree runs with where placement was ASKED FOR (on)
  ## and could not happen. With placement off only a reclaimed tree is
  ## lowered (its nice +10), as before cgroup placement existed.
  if reclaimed: ReclaimedNiceIncrement
  elif priority == sessionPriorityLow: LowPriorityNiceIncrement
  else: 0

proc nameByteKept(ch: char): bool =
  ch in {'A'..'Z', 'a'..'z', '0'..'9', '_', ':', '@', '-'}

proc escapeGroupName*(name: string): string =
  ## The group name as one safe cgroup directory name component. Every byte
  ## outside `[A-Za-z0-9_:@-]` becomes `%XX` (upper-case hex), so the result
  ## never contains `/`, `.`, `%` unescaped, a control byte or a non-ASCII
  ## byte: it cannot climb out of the root (`..`), name a nested path, or
  ## collide with a kernel interface file. The mapping is injective, so two
  ## groups never share a directory. A result longer than
  ## `MaxEscapedNameBytes` keeps its first `KeptEscapedNameBytes` bytes and
  ## ends in `~` and the first `NameHashHexDigits` hex digits of the whole
  ## name's SHA-256 (`~` is never produced by the escaping, so a shortened
  ## name cannot equal an unshortened one), which keeps every name inside
  ## `NAME_MAX` (255) with the `group-` prefix.
  result = newStringOfCap(name.len)
  for ch in name:
    if nameByteKept(ch):
      result.add(ch)
    else:
      result.add('%')
      result.add(toHex(ord(ch), 2))
  if result.len > MaxEscapedNameBytes:
    var cut = KeptEscapedNameBytes
    # Do not split a `%XX` escape.
    while cut > 0 and (result[cut - 1] == '%' or
        (cut >= 2 and result[cut - 2] == '%')):
      dec cut
    result = result[0 ..< cut] & "~" &
      sha256Hex(name)[0 ..< NameHashHexDigits]

proc groupDirName*(group: string): string =
  ## The directory of a session group below the root. A session without a
  ## group is in its user's `interactive` group.
  let name = if group.len == 0: InteractiveSessionGroup else: group
  GroupDirPrefix & escapeGroupName(name)

proc cpuMaxFor*(grantedMilli: uint64): string =
  ## `cpu.max` for a cap at `grantedMilli` milli-CPU: a quota of
  ## `grantedMilli * 100` µs per 100 000 µs period, so 1000 milli-CPU is one
  ## CPU's worth of time per period. Never below the kernel's 1 ms minimum.
  let quota = max(grantedMilli * uint64(CpuMaxPeriodMicros) div 1000'u64,
    uint64(MinCpuMaxQuotaMicros))
  $quota & " " & $CpuMaxPeriodMicros

proc capLeafName*(launcherPid: int; sequence: int): string =
  CapLeafPrefix & $launcherPid & "-" & $sequence

proc parseOwnCgroup*(procSelfCgroup: string): string =
  ## The cgroup v2 path of a process, from its `/proc/<pid>/cgroup` text
  ## (the `0::<path>` line), or "" when there is none (cgroup v1 only).
  for line in procSelfCgroup.splitLines():
    if line.startsWith("0::"):
      return line[3 .. ^1]
  ""

proc explicitRootProblem*(path: string): string =
  ## Why `path` cannot be a cgroup root, or "" when it can. It must be an
  ## absolute path strictly inside the cgroup v2 mount, with no `.` or `..`
  ## component (which could leave the subtree the caller meant) and no NUL
  ## or newline.
  if path.len == 0:
    return "the root is empty"
  for ch in path:
    if ch == '\0' or ch == '\n' or ch == '\r':
      return "the root contains a NUL or newline byte"
  if not path.startsWith(CgroupMountPoint & "/"):
    return "the root must be inside " & CgroupMountPoint & ", got " & path
  for component in path[CgroupMountPoint.len + 1 .. ^1].split('/'):
    if component == "." or component == "..":
      return "the root must not contain a . or .. component: " & path
  if path[CgroupMountPoint.len + 1 .. ^1].strip(chars = {'/'}).len == 0:
    return "the root must be below " & CgroupMountPoint & ", not the mount itself"
  ""

proc defaultRootFor*(ownCgroup: string; uid: int): string =
  ## `runquota.slice` below the `user@<uid>.service` cgroup that contains
  ## `ownCgroup`, or "" when the caller is not inside its own user manager's
  ## subtree (a system service, a container, a job under another manager):
  ## that is the subtree systemd delegates to the user.
  let service = "user@" & $uid & ".service"
  var prefix = ""
  for component in ownCgroup.split('/'):
    if component.len == 0:
      continue
    prefix.add("/" & component)
    if component == service:
      return CgroupMountPoint & prefix & "/" & DefaultRootName
  ""

proc resolveCgroupRoot*(envValue, procSelfCgroup: string; uid: int;
                        hostSwitchOn: bool; isLinux = defined(linux)):
    CgroupRoot =
  ## The root a launcher of user `uid` places trees under, from the value of
  ## `RUNQUOTA_CGROUP_ROOT`, the host file's `[enforcement] cgroups`
  ## (`hostSwitchOn`) and its own `/proc/self/cgroup` text. Pure: the inputs
  ## are what `currentCgroupRoot` reads.
  ##
  ## PRECEDENCE: the variable's `off` wins over everything; an explicit root
  ## in it turns placement on under that root; with the variable unset the
  ## host switch decides, and it is off unless the host file turns it on
  ## (placement has not passed the overhead gate; the specification's
  ## enforcement switches).
  let value = envValue.strip()
  if value == CgroupRootOff:
    return CgroupRoot(state: crsOff,
      reason: "turned off by " & CgroupRootEnvVar & "=off")
  if value.len == 0 and not hostSwitchOn:
    return CgroupRoot(state: crsOff,
      reason: "off by default (the host file does not set [enforcement] " &
        "cgroups = \"on\")")
  if not isLinux:
    return CgroupRoot(state: crsUnavailable,
      reason: "cgroups exist only on Linux")
  if value.len > 0:
    let problem = explicitRootProblem(value)
    if problem.len > 0:
      return CgroupRoot(state: crsUnavailable,
        reason: CgroupRootEnvVar & ": " & problem)
    return CgroupRoot(state: crsExplicit, path: value.strip(leading = false,
      chars = {'/'}))
  let own = parseOwnCgroup(procSelfCgroup)
  if own.len == 0:
    return CgroupRoot(state: crsUnavailable,
      reason: "no cgroup v2 hierarchy (no 0:: line in /proc/self/cgroup)")
  let root = defaultRootFor(own, uid)
  if root.len == 0:
    return CgroupRoot(state: crsUnavailable,
      reason: "this process (cgroup " & own & ") is not inside user@" & $uid &
        ".service, the subtree systemd delegates to the user; set " &
        CgroupRootEnvVar & " to a delegated cgroup")
  CgroupRoot(state: crsDefault, path: root)

proc usable*(root: CgroupRoot): bool =
  root.state in {crsDefault, crsExplicit}

proc targetFor*(root: CgroupRoot; group: string; priority: SessionPriority;
                reclaimed: bool; capMilli = 0'u64; launcherPid = 0;
                capSequence = 0): CgroupTarget =
  ## Where a tree of `group` at `priority` goes; reclaimed trees go to the
  ## reclaimed subtree whatever their group. `capMilli > 0` asks for a cap
  ## leaf of its own. An unusable root gives an empty target (no placement).
  if not root.usable:
    return CgroupTarget()
  result.root = root.path
  if reclaimed:
    result.dirName = ReclaimedDirName
    result.cpuWeight = ReclaimedCpuWeight
  else:
    result.dirName = groupDirName(group)
    result.cpuWeight = cpuWeightFor(priority)
  if capMilli > 0'u64:
    result.leafName = capLeafName(launcherPid, capSequence)
    result.cpuMax = cpuMaxFor(capMilli)
  else:
    result.leafName = SharedLeafName

# ---------------------------------------------------------------------------
# The host
# ---------------------------------------------------------------------------

proc currentCgroupRoot*(hostSwitchOn = false): CgroupRoot =
  ## The root for this process, from its environment, the host switch the
  ## caller read (`[enforcement] cgroups`; a library caller that reads no
  ## host file passes nothing, so only an explicit root turns placement on)
  ## and its own cgroup.
  ##
  ## OFF COSTS NOTHING. `/proc/self/cgroup` and the effective uid are read
  ## only when the answer can depend on them (the default root with the host
  ## switch on): with placement off a launch must make no system call it did
  ## not make before placement existed.
  when defined(linux):
    let value = getEnv(CgroupRootEnvVar).strip()
    var own = ""
    var uid = 0
    if value.len == 0 and hostSwitchOn:
      uid = int(geteuid())
      try:
        own = readFile("/proc/self/cgroup")
      except IOError, OSError:
        own = ""
    resolveCgroupRoot(value, own, uid, hostSwitchOn)
  else:
    resolveCgroupRoot(getEnv(CgroupRootEnvVar), "", 0, hostSwitchOn)

proc readSmall(path: string): string =
  try: readFile(path) except IOError, OSError: ""

when defined(posix):
  proc errnoText(): string =
    $strerror(errno)

  proc removedErrno(code: cint): bool =
    ## The errors a cgroup operation gets when a directory it names was
    ## removed meanwhile: ENOENT for a path that is gone, ENODEV for a file
    ## descriptor of a removed cgroup.
    code == ENOENT or code == ENODEV

  proc writeCgroupFile(path, text: string; problem: var string;
                       vanished: var bool): bool =
    ## One write of `text` to a cgroup interface file. The kernel takes each
    ## write as one command, so it is written in one call. `vanished` when
    ## the cgroup was removed under the write.
    let fd = posix.open(cstring(path), O_WRONLY or O_CLOEXEC)
    if fd < 0:
      vanished = removedErrno(errno)
      problem = "cannot open " & path & ": " & errnoText()
      return false
    let written = posix.write(fd, cstring(text), text.len)
    let saved = errno
    discard posix.close(fd)
    if written != text.len:
      errno = saved
      vanished = removedErrno(saved)
      problem = "cannot write '" & text & "' to " & path & ": " & errnoText()
      return false
    true

  proc writeCgroupFile(path, text: string; problem: var string): bool =
    var vanished = false
    writeCgroupFile(path, text, problem, vanished)

  proc ensureDir(path: string; problem: var string; vanished: var bool): bool =
    if posix.mkdir(cstring(path), 0o755) == 0 or errno == EEXIST:
      return true
    # ENOENT: the parent was removed meanwhile (another launcher's clean-up).
    vanished = errno == ENOENT
    problem = "cannot create cgroup " & path & ": " & errnoText()
    false

  proc hasController(listText, name: string): bool =
    name in listText.splitWhitespace()

  proc readCgroupFile(path: string; text: var string; problem: var string;
                      vanished: var bool): bool =
    ## The contents of a (small) cgroup interface file. False with
    ## `problem` when it cannot be read; `vanished` when that is because
    ## its cgroup was removed meanwhile (ENOENT on the open, ENODEV on the
    ## read of a removed cgroup), which is not a delegation problem.
    text = ""
    let fd = posix.open(cstring(path), O_RDONLY or O_CLOEXEC)
    if fd < 0:
      vanished = removedErrno(errno)
      problem = "cannot open " & path & ": " & errnoText()
      return false
    var buffer: array[512, char]
    while true:
      let got = posix.read(fd, addr buffer[0], buffer.len)
      if got > 0:
        for i in 0 ..< got: text.add(buffer[i])
      elif got == 0:
        break
      elif errno != EINTR:
        let saved = errno
        discard posix.close(fd)
        errno = saved
        vanished = removedErrno(saved)
        problem = "cannot read " & path & ": " & errnoText()
        return false
    discard posix.close(fd)
    true

  proc enableCpuBelow(dir: string; problem: var string;
                      vanished: var bool): bool =
    ## `+cpu` in `dir/cgroup.subtree_control`, unless it is already there.
    ## Every read and write tells a directory that another launcher's
    ## clean-up removed meanwhile (`vanished`) from one whose parent does
    ## not delegate the controller, because only the first is worth a retry.
    var enabled = ""
    if not readCgroupFile(dir / "cgroup.subtree_control", enabled, problem,
        vanished):
      return false
    if hasController(enabled, "cpu"):
      return true
    var available = ""
    if not readCgroupFile(dir / "cgroup.controllers", available, problem,
        vanished):
      return false
    if not hasController(available, "cpu"):
      problem = "the cpu controller is not available in " & dir &
        " (not delegated: its parent does not enable it for its children)"
      return false
    writeCgroupFile(dir / "cgroup.subtree_control", "+cpu", problem, vanished)

proc prepareTarget*(target: CgroupTarget; problem: var string;
                    vanished: var bool): bool =
  ## Create (or confirm) the root, the group or reclaimed directory with its
  ## weight, and the leaf (with its `cpu.max` for a cap leaf). Idempotent and
  ## safe against other launchers doing the same at the same time: every
  ## step accepts what an earlier or concurrent one already did. On failure
  ## `problem` says which step and why, and nothing is undone (an empty
  ## directory left behind is reused or cleaned up by the next launch).
  ##
  ## `vanished` is set when the failure is another launcher's clean-up
  ## removing the group directory or the leaf between two steps (the last
  ## tree of a group ended): preparing again then succeeds, and the
  ## launcher retries rather than leave its tree unplaced.
  vanished = false
  when defined(linux):
    if not target.placed:
      problem = "no cgroup root"
      return false
    if not ensureDir(target.root, problem, vanished): return false
    if not enableCpuBelow(target.root, problem, vanished): return false
    let dir = target.dirPath
    if not ensureDir(dir, problem, vanished): return false
    if not writeCgroupFile(dir / "cpu.weight", $target.cpuWeight, problem,
        vanished):
      return false
    if not enableCpuBelow(dir, problem, vanished): return false
    let leaf = target.leafPath
    if not ensureDir(leaf, problem, vanished): return false
    if target.cpuMax.len > 0:
      if not writeCgroupFile(leaf / "cpu.max", target.cpuMax, problem,
          vanished):
        return false
    true
  else:
    problem = "cgroups exist only on Linux"
    false

proc prepareTarget*(target: CgroupTarget; problem: var string): bool =
  var vanished = false
  prepareTarget(target, problem, vanished)

when defined(linux):
  proc flock(fd: cint; operation: cint): cint {.importc, header: "<sys/file.h>".}
  var
    LOCK_SH {.importc, header: "<sys/file.h>".}: cint
    LOCK_EX {.importc, header: "<sys/file.h>".}: cint

proc lockCgroupRoot*(root: string; exclusive: bool): cint =
  ## Hold the root's lock: SHARED by a launcher from preparing its leaf until
  ## its child is in it, EXCLUSIVE by a clean-up while it removes empty
  ## directories. So a clean-up never removes a directory between another
  ## launcher's preparation and its child's join (the group's `shared` leaf
  ## is used by every tree of the group, and empties whenever one ends), and
  ## launchers never wait for each other. A `flock(2)` on the root
  ## directory, which is never removed; it is created here if missing.
  ## Returns the descriptor to pass to `unlockCgroupRoot`, or -1 when the
  ## root cannot be opened or locked: the caller goes on unlocked, and a
  ## directory removed under it is then retried (`openPreparedProcs`).
  ## https://man7.org/linux/man-pages/man2/flock.2.html
  when defined(linux):
    if root.len == 0:
      return -1
    discard posix.mkdir(cstring(root), 0o755)
    let fd = posix.open(cstring(root), O_RDONLY or O_CLOEXEC)
    if fd < 0:
      return -1
    let operation = if exclusive: LOCK_EX else: LOCK_SH
    while flock(fd, operation) != 0:
      if errno != EINTR:
        discard posix.close(fd)
        return -1
    fd
  else:
    -1

proc unlockCgroupRoot*(fd: cint) =
  ## Release a lock `lockCgroupRoot` took (closing its descriptor drops it).
  when defined(posix):
    if fd >= 0:
      discard posix.close(fd)

proc removeEmptyCgroup*(path: string): bool =
  ## `rmdir` of a cgroup directory. The kernel refuses (EBUSY) while it
  ## holds a process or a child cgroup, which is what makes the last one out
  ## the one that removes it; that and an already-removed directory are not
  ## errors. True when the directory is gone.
  when defined(posix):
    if posix.rmdir(cstring(path)) == 0:
      return true
    errno == ENOENT
  else:
    false

proc releaseTarget*(target: CgroupTarget) =
  ## After a tree ended: remove its leaf, then its group (or reclaimed)
  ## directory, each only if empty, under the root's exclusive lock
  ## (`lockCgroupRoot`), so no other launcher is between preparing the leaf
  ## and its child's join. The root is never removed. The caller must not
  ## hold the root's shared lock itself.
  if not target.placed:
    return
  let lock = lockCgroupRoot(target.root, exclusive = true)
  if removeEmptyCgroup(target.leafPath):
    discard removeEmptyCgroup(target.dirPath)
  unlockCgroupRoot(lock)

proc pidAlive(pid: int): bool =
  when defined(posix):
    pid > 0 and (posix.kill(Pid(pid), 0) == 0 or errno == EPERM)
  else:
    true

proc sweepStaleCapLeaves*(target: CgroupTarget) =
  ## Remove the empty `cap-<pid>-<n>` leaves of launchers that are gone, in
  ## the directory `target` caps into. A leaf whose launcher died before
  ## its clean-up would otherwise stay for good. Only empty leaves go (the
  ## kernel refuses the others), and only those of dead launchers, so a
  ## concurrent launcher's fresh leaf is never taken from under it.
  if not target.placed:
    return
  try:
    for kind, path in walkDir(target.dirPath, relative = true):
      if kind != pcDir or not path.startsWith(CapLeafPrefix):
        continue
      let parts = path[CapLeafPrefix.len .. ^1].split('-')
      if parts.len != 2:
        continue
      var pid = 0
      try:
        pid = parseInt(parts[0])
      except ValueError:
        continue
      if not pidAlive(pid):
        discard removeEmptyCgroup(target.dirPath / path)
  except OSError:
    discard

proc cgroupOfPid*(pid: int): string =
  ## The cgroup v2 path of `pid` (relative to the mount), or "".
  parseOwnCgroup(readSmall("/proc/" & $pid & "/cgroup"))

proc probeRoot*(root: CgroupRoot): string =
  ## Whether trees could be placed under `root` on this host, WITHOUT
  ## creating anything: "" when they could, else why not. Used by the
  ## capability record, which `runquota status` prints, and a status query
  ## must not create the user's cgroups as a side effect.
  if not root.usable:
    return root.reason
  when defined(linux):
    if dirExists(root.path):
      if not hasController(readSmall(root.path / "cgroup.controllers"), "cpu"):
        return "the cpu controller is not available in " & root.path
      if posix.access(cstring(root.path), W_OK) != 0:
        return "cannot write " & root.path & ": " & errnoText()
      return ""
    let parent = root.path.parentDir
    if not dirExists(parent):
      return "the parent of the cgroup root does not exist: " & parent
    if not hasController(readSmall(parent / "cgroup.subtree_control"), "cpu"):
      return "the cpu controller is not delegated to " & parent &
        " (missing from its cgroup.subtree_control)"
    if posix.access(cstring(parent), W_OK) != 0:
      return "cannot create the cgroup root in " & parent & ": " & errnoText()
    ""
  else:
    "cgroups exist only on Linux"

proc rewriteGroupWeight*(root: CgroupRoot; group: string;
                         priority: SessionPriority): string =
  ## After a group's priority changed (`runquota session set --priority`):
  ## write the new weight to its directory, if this user has one now. A
  ## group with no running placed tree has no directory, and the next tree
  ## writes the weight in force when it prepares one, so "absent" is not a
  ## problem. Returns "" when written or absent, otherwise why not.
  if not root.usable:
    return ""
  let dir = root.path / groupDirName(group)
  when defined(linux):
    if not dirExists(dir):
      return ""
    var problem = ""
    if not writeCgroupFile(dir / "cpu.weight", $cpuWeightFor(priority),
        problem):
      return problem
    ""
  else:
    ""

proc openPreparedProcs*(target: CgroupTarget; problem: var string;
                        retryable: var bool): cint =
  ## Prepare `target` and open its leaf's `cgroup.procs` for writing
  ## (close-on-exec), for a forked child to write itself into before it
  ## executes. -1 on failure with `problem` set; `retryable` when the leaf
  ## vanished after it was prepared (another launcher's clean-up removed
  ## it), so preparing it again can succeed.
  retryable = false
  when defined(linux):
    var vanished = false
    if not prepareTarget(target, problem, vanished):
      retryable = vanished
      return -1
    let procs = target.leafPath / "cgroup.procs"
    let fd = posix.open(cstring(procs), O_WRONLY or O_CLOEXEC)
    if fd < 0:
      let saved = errno
      problem = "cannot open " & procs & ": " & $strerror(saved)
      retryable = removedErrno(saved)
    fd
  else:
    problem = "cgroups exist only on Linux"
    -1

proc moveIntoTarget*(target: CgroupTarget; pid: int;
                     problem: var string): bool =
  ## Prepare `target` again and move process `pid` into its leaf: the
  ## parent's half of the vanished-leaf retry, for a child that is waiting,
  ## not yet executed, after its own write found the leaf gone.
  when defined(linux):
    if not prepareTarget(target, problem):
      return false
    writeCgroupFile(target.leafPath / "cgroup.procs", $pid, problem)
  else:
    problem = "cgroups exist only on Linux"
    false
