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
##   <root>/                      cgroup.subtree_control += cpu (+ memory)
##     group-<escaped name>/      cpu.weight from the group's priority
##       shared/                  every uncapped tree of the group
##       cap-<pid>-<n>/           one capped tree: cpu.max = its CPU grant,
##                                and/or memory.max = its memory cap
##     reclaimed/                 cpu.weight 1
##       shared/, cap-<pid>-<n>/
##
## THE MEMORY CAP (`memoryCapTarget`). A tree with a memory cap gets a leaf
## of its own (one leaf carries both caps when a CPU cap applies too), with
## `memory.max` = the cap (`max` when the cap only measures),
## `memory.swap.max` = 0 for an enforced cap only (a capped tree must not
## hide its growth in swap; a measured one must not be changed) and
## `memory.oom.group` = 1, so the kernel's OOM killer kills the WHOLE tree or
## nothing: without it it picks one victim, and a `make` or a shell can
## survive the compiler it started. `+memory` is enabled in the root's and
## the group directory's `cgroup.subtree_control`, beside `+cpu`. The memory
## interface files are documented at
## https://docs.kernel.org/admin-guide/cgroup-v2.html#memory-interface-files
##
## TRAP 1: NO ANCESTOR OF A LEAF SETS `memory.oom.group`. On an OOM, the
## kernel (`mem_cgroup_get_oom_group`) kills the HIGHEST cgroup with
## `oom.group` set between the victim and the cgroup whose limit was hit; on
## a host-wide OOM that is anywhere up to the top. A group directory with it
## set would turn one tree's host-OOM kill into the kill of every tree of
## the group. So only the leaf this module creates for a capped tree ever
## gets it, and `probeMemory` reports any ancestor that has it.
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

import std/[monotimes, os, strutils, times]
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
  GroupKillSettleMillis* = 2_000
    ## How long `close` waits for a leaf the OOM killer killed as a group
    ## to empty before removing it.
  CapLeafNameAttempts* = 4
    ## How many names a launch tries for a cap leaf of its own when the one
    ## it was given already exists (`CgroupTarget.freshLeaf`).

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
    memory*: bool
      ## Enable the memory controller (`+memory`) in the root's and the
      ## group directory's `cgroup.subtree_control`, so the leaf has the
      ## memory interface files. Set for a tree with a memory cap (or a
      ## measured one), at every stage of `MemoryCapStage`.
    memoryMax*: string
      ## "" writes no memory limit. Otherwise the leaf's `memory.max` text
      ## (bytes, or `max` for a tree that is only measured), written
      ## together with `memory.oom.group` = 1 and, for an enforced cap
      ## (bytes) only, `memory.swap.max` = 0.
      ## Only ever on a leaf of its own (`freshLeaf`): never on a shared
      ## leaf, and never on a directory above a leaf (trap 1, above).
    freshLeaf*: bool
      ## The leaf must be CREATED by this preparation, not found: a cap leaf
      ## holds exactly one tree. Two trees in one memory-capped leaf would
      ## die together, and a leaf left over from an earlier tree would hand
      ## this tree that tree's `memory.events.local` counts and
      ## `memory.peak`, which the classification reads. An existing leaf of
      ## that name is reported (`MemoryPreparation.leafTaken`), and the
      ## launcher picks another name.

  MemoryCapStage* = enum
    ## How much of the Linux memory-cap mechanism a launch applies. Only the
    ## overhead gate asks for less than all of it (`MemoryCapStageEnvVar`),
    ## so that each stage's cost can be measured on its own; each stage
    ## includes the ones before it.
    mcsController = "controller"
      ## `+memory` in the root's and the group's `cgroup.subtree_control`
      ## only; the tree stays in the leaf it would have had without a cap.
    mcsLeaf = "leaf"
      ## And a leaf of its own per capped tree, entered by an ordinary
      ## `fork` with no limits written.
    mcsLimits = "limits"
      ## And the limit writes (`memory.max`, `memory.swap.max`,
      ## `memory.oom.group`), and spawning with `clone3(CLONE_INTO_CGROUP)`.
    mcsClassify = "classify"
      ## And the reads at the end of the tree that classify how it ended
      ## (`memory.events.local`, `memory.peak`). The full mechanism.

  MemoryPreparation* = object
    ## What `prepareTarget` did about a target's memory settings. None of
    ## it can fail a placement: a tree whose memory controller or limits
    ## could not be set still runs in its leaf, and `problem` says why the
    ## cap is not on it.
    controller*: bool
      ## The memory controller is enabled for the leaf (in the group
      ## directory's `cgroup.subtree_control`, and so in the root's).
    limits*: bool
      ## `memory.max`, `memory.oom.group` (and `memory.swap.max` where the
      ## kernel accounts swap) were written to the leaf.
    leafTaken*: bool
      ## A `freshLeaf` target's leaf already existed: nothing was written to
      ## it, and the caller must pick another name.
    leafCreated*: bool
      ## This preparation created the leaf. A launch that must prepare
      ## again (a later step found something vanished) reuses that leaf
      ## under the same name instead of taking a new one.
    problem*: string
      ## Why the memory settings asked for are not (all) in place, or "".

  MemoryEvents* = object
    ## The two counts that classify a tree's end, each from the file that
    ## answers its question (kernel `memcg_memory_event`: an event is
    ## counted in the cgroup's `memory.events.local` and in the
    ## hierarchical `memory.events` of it and every ancestor):
    ##
    ## * `oom`, from the leaf's `memory.events.local`: raised on the cgroup
    ##   whose LIMIT was hit, so the leaf's own count says the CAP was hit.
    ##   Its hierarchical count would also take in a limit of the tree's own
    ##   below the leaf, which is not the cap.
    ## * `oomKill`, from the leaf's hierarchical `memory.events`: raised on
    ##   the memory cgroup of each killed process, whoever's limit it was.
    ##   A tree that enables the memory controller below its leaf has its
    ##   processes, and their kills, counted in sub-cgroups, so only the
    ##   hierarchical count sees every kill inside the tree's leaf.
    known*: bool
    oom*: uint64
    oomKill*: uint64

  MemoryCapVerdict* = object
    ## How a capped or measured tree ended, as far as memory goes
    ## (`memoryCapVerdict`).
    capExceeded*: bool
    capKilled*: bool
    capReached*: bool
    oomKilledOutsideCap*: bool

  GroupPriorityRead* = proc (context: pointer;
                             priority: var SessionPriority): bool {.
    nimcall, gcsafe, raises: [].}
    ## Asks whoever holds the group's priority (the daemon) for the one in
    ## force NOW. False when it cannot answer; the caller then keeps the
    ## weight it already had. Must not raise, and must be GC-safe:
    ## `launchProcess` calls it, and a launcher that is itself called from
    ## GC-safe code (a thread procedure, a `{.gcsafe.}` callback in a
    ## consumer) stops compiling if one indirect call here is not.

  GroupPrioritySource* = object
    ## Where the priority of a group's weight is read at the moment the
    ## weight is written. A launcher calls it while it holds the root's
    ## SHARED lock, between taking the lock and writing the weight; `session
    ## set --priority` calls it while it holds the lock EXCLUSIVE. That is
    ## what makes the last weight written always the priority in force (see
    ## `lockCgroupRoot`). Plain data, so it can ride on a launch spec of
    ## this static-helper library: a procedure and an untyped context the
    ## procedure alone interprets, which must stay valid for as long as the
    ## source can be called (the caller's launch).
    read*: GroupPriorityRead
    context*: pointer

proc available*(source: GroupPrioritySource): bool =
  ## Whether `source` names a reader at all.
  not source.read.isNil

proc readNow*(source: GroupPrioritySource;
              priority: var SessionPriority): bool =
  ## The priority in force through `source`, or false when there is no
  ## reader or it could not answer.
  if source.read.isNil:
    return false
  source.read(source.context, priority)

proc placed*(target: CgroupTarget): bool =
  ## Whether `target` asks for any placement at all.
  target.root.len > 0

proc dirPath*(target: CgroupTarget): string =
  target.root / target.dirName

proc leafPath*(target: CgroupTarget): string =
  target.root / target.dirName / target.leafName

proc isCapLeaf*(target: CgroupTarget): bool =
  target.leafName.startsWith(CapLeafPrefix)

proc hasMemoryLimits*(target: CgroupTarget): bool =
  ## Whether preparing `target` writes memory limits into its leaf.
  target.memoryMax.len > 0

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

proc parseMemoryCapStage*(text: string; stage: var MemoryCapStage): bool =
  ## The stage `RUNQUOTA_MEMORY_CAP_STAGE` names: unset or empty is the
  ## whole mechanism (`mcsClassify`). False for any other text, and `stage`
  ## is then the whole mechanism too: the variable is the overhead gate's,
  ## and a value it does not know must not quietly turn the cap off.
  let value = text.strip()
  stage = mcsClassify
  if value.len == 0:
    return true
  for candidate in MemoryCapStage:
    if value == $candidate:
      stage = candidate
      return true
  false

proc memoryMaxFor*(capBytes: uint64; action: MemoryCapAction): string =
  ## The leaf's `memory.max` text for a cap of `capBytes`: the cap itself
  ## when it is enforced; `max` (no limit, measured only) for an advisory
  ## cap and for a lifted run (`capBytes` 0).
  if capBytes == 0'u64 or action == mcaAdvisory: "max"
  else: $capBytes

proc memoryCapTarget*(target: CgroupTarget; capBytes: uint64;
                      action: MemoryCapAction; stage: MemoryCapStage;
                      launcherPid, sequence: int): CgroupTarget =
  ## `target` with the memory cap of `capBytes` (0: measured only) applied
  ## up to `stage`. Pure. A target that is not placed is returned as it is
  ## (a cap needs a cgroup root). A target that already has a leaf of its
  ## own (a CPU cap) keeps it, so one leaf carries both caps; otherwise the
  ## tree gets `cap-<launcherPid>-<sequence>`.
  result = target
  if not target.placed:
    return
  result.memory = true
  if stage >= mcsLeaf:
    if not result.isCapLeaf:
      result.leafName = capLeafName(launcherPid, sequence)
    result.freshLeaf = true
  if stage >= mcsLimits:
    result.memoryMax = memoryMaxFor(capBytes, action)

proc parseMemoryEvents*(text: string): MemoryEvents =
  ## The `oom` and `oom_kill` counts of a `memory.events.local` text
  ## (`<key> <count>` per line). Unknown when either key is missing or is
  ## not a count: an absent figure must not read as a zero.
  var haveOom, haveKill = false
  for line in text.splitLines():
    let fields = line.splitWhitespace()
    if fields.len != 2:
      continue
    var value: BiggestUInt
    try:
      value = parseBiggestUInt(fields[1])
    except ValueError:
      continue
    case fields[0]
    of "oom":
      result.oom = uint64(value)
      haveOom = true
    of "oom_kill":
      result.oomKill = uint64(value)
      haveKill = true
    else:
      discard
  result.known = haveOom and haveKill

proc memoryCapVerdict*(events: MemoryEvents; peakBytes, capBytes: uint64;
                       action: MemoryCapAction;
                       killEvidence: bool): MemoryCapVerdict =
  ## How a tree in a memory-capped (or measured) leaf ended, from the
  ## leaf's own `memory.events.local` and `memory.peak`, read after its
  ## root was reaped. Pure.
  ##
  ## * `oom` >= 1 and `oom_kill` >= 1, and the root ended with kill evidence
  ##   (a signal, or a non-zero exit from a parent that reported its
  ##   child's kill): the CAP was hit and the OOM killer killed in the leaf.
  ##   Cap exceeded, killed.
  ##   Without kill evidence (a root the group kill skipped, or one that
  ##   had already ended): cap reached, so the run is never learned from.
  ## * `oom` >= 1 and `oom_kill` = 0: the cap was hit and an allocation was
  ##   refused (ENOMEM: the kernel fails some allocations at the limit
  ##   instead of killing), nothing was killed. Cap reached.
  ## * `oom_kill` >= 1 and `oom` = 0: a process of the tree was killed for
  ##   memory, but not because of the cap: a host-wide OOM, or the limit of
  ##   an ancestor. Killed outside the cap.
  ## * Otherwise the root's own conclusion; in advisory mode a peak above
  ##   the cap is a breach that killed nothing.
  ##
  ## `oom` is the leaf's LOCAL count and `oomKill` its HIERARCHICAL one
  ## (`MemoryEvents`): the hierarchical `oom` would read a limit of the
  ## tree's own below the leaf as the cap, and the local `oom_kill` would
  ## miss a cap kill of a process the tree had moved into a sub-cgroup with
  ## a memory controller of its own.
  if not events.known:
    return
  if events.oom >= 1'u64 and events.oomKill >= 1'u64:
    if killEvidence:
      result.capExceeded = true
      result.capKilled = true
    else:
      # The cap was hit and the kernel killed in the leaf, but not the
      # root: one it skipped (`oom_score_adj` -1000) or one that had ended.
      # A root that then exits 0 must not read as a clean, measured run,
      # or the learned maximum would rise to about the cap.
      result.capReached = true
  elif events.oom >= 1'u64:
    result.capReached = true
  elif events.oomKill >= 1'u64:
    result.oomKilledOutsideCap = true
  if action == mcaAdvisory and capBytes > 0'u64 and peakBytes > capBytes:
    result.capExceeded = true

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

const runquotaHideMemoryFile {.strdefine.} = ""
  ## TESTS ONLY: the name of one memory interface file the launcher should
  ## look for under a name that does not exist, so a test can stand for a
  ## kernel that lacks it (`memory.oom.group` before 4.19, `memory.peak`
  ## before 5.19). Empty in every real build, where `memoryFile` is the
  ## identity and costs nothing.

proc memoryFile(name: string): string =
  ## `name`, unless a test build hides it (`runquotaHideMemoryFile`).
  when runquotaHideMemoryFile.len > 0:
    if name == runquotaHideMemoryFile:
      return name & ".hidden-by-test"
  name

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

  proc enableControllerBelow(dir, controller: string; problem: var string;
                             vanished: var bool): bool =
    ## `+<controller>` in `dir/cgroup.subtree_control`, unless it is already
    ## there. Every read and write tells a directory that another launcher's
    ## clean-up removed meanwhile (`vanished`) from one whose parent does
    ## not delegate the controller, because only the first is worth a retry.
    var enabled = ""
    if not readCgroupFile(dir / "cgroup.subtree_control", enabled, problem,
        vanished):
      return false
    if hasController(enabled, controller):
      return true
    var available = ""
    if not readCgroupFile(dir / "cgroup.controllers", available, problem,
        vanished):
      return false
    if not hasController(available, controller):
      problem = "the " & controller & " controller is not available in " &
        dir & " (not delegated: its parent does not enable it for its " &
        "children)"
      return false
    writeCgroupFile(dir / "cgroup.subtree_control", "+" & controller, problem,
      vanished)

  proc enableCpuBelow(dir: string; problem: var string;
                      vanished: var bool): bool =
    enableControllerBelow(dir, "cpu", problem, vanished)

  proc ensureFreshDir(path: string; problem: var string; vanished,
                      taken: var bool): bool =
    ## `mkdir` that must CREATE the directory: an existing one is `taken`.
    if posix.mkdir(cstring(path), 0o755) == 0:
      return true
    if errno == EEXIST:
      taken = true
      problem = "cgroup " & path & " already exists; a cap leaf holds one " &
        "tree only"
      return false
    vanished = errno == ENOENT
    problem = "cannot create cgroup " & path & ": " & errnoText()
    false

  proc writeMemoryLimits(target: CgroupTarget; memory: var MemoryPreparation;
                         vanished: var bool): bool =
    ## The leaf's memory limits, in an order that never leaves a limit
    ## without the group kill: `memory.swap.max` (enforced caps only) and
    ## `memory.oom.group` first, `memory.max` last, so a leaf whose `oom.group` cannot be set
    ## gets no limit at all rather than a limit under which the kernel kills
    ## one process and leaves its parent running. False only when the LEAF
    ## vanished (the caller prepares again). An interface file that does
    ## not exist in a leaf that does (ENOENT from a kernel without it:
    ## `memory.oom.group` before 4.19) is not a vanished leaf: like every
    ## other failure it is a `memory.problem`, and the tree runs in its
    ## leaf, with any CPU cap, without the memory cap.
    let leaf = target.leafPath
    var problem = ""
    var gone = false
    # No swap for an ENFORCED cap: the cap is on memory the tree holds, and
    # a tree that can push its growth into swap passes the cap unseen. Not
    # for a leaf that only measures (`max`: advisory mode, a lifted run),
    # which must not change how the tree uses memory. A kernel that does
    # not account swap has no such file, and nothing to escape into.
    if target.memoryMax != "max" and fileExists(leaf / memoryFile("memory.swap.max")):
      if not writeCgroupFile(leaf / memoryFile("memory.swap.max"), "0", problem, gone):
        if gone and not dirExists(leaf):
          vanished = true
          memory.problem = problem
          return false
        memory.problem = "memory cap not applied: " & problem
        return true
    if not writeCgroupFile(leaf / memoryFile("memory.oom.group"), "1", problem, gone):
      if gone and not dirExists(leaf):
        vanished = true
        memory.problem = problem
        return false
      memory.problem = "memory cap not applied: " & problem
      return true
    if not writeCgroupFile(leaf / memoryFile("memory.max"), target.memoryMax, problem,
        gone):
      if gone and not dirExists(leaf):
        vanished = true
        memory.problem = problem
        return false
      memory.problem = "memory cap not applied: " & problem
      return true
    memory.limits = true
    true

proc prepareTarget*(target: CgroupTarget; problem: var string;
                    vanished: var bool;
                    memory: var MemoryPreparation): bool =
  ## Create (or confirm) the root, the group or reclaimed directory with its
  ## weight, and the leaf (with its `cpu.max` for a cap leaf, and its memory
  ## limits for a memory-capped one). Idempotent and safe against other
  ## launchers doing the same at the same time: every step accepts what an
  ## earlier or concurrent one already did, except the creation of a
  ## `freshLeaf`. On failure `problem` says which step and why, and nothing
  ## is undone (an empty directory left behind is reused or cleaned up by
  ## the next launch).
  ##
  ## `vanished` is set when the failure is another launcher's clean-up
  ## removing the group directory or the leaf between two steps (the last
  ## tree of a group ended): preparing again then succeeds, and the
  ## launcher retries rather than leave its tree unplaced.
  ##
  ## THE MEMORY SETTINGS NEVER FAIL THE PLACEMENT. A memory controller that
  ## cannot be enabled, or a limit that cannot be written, leaves the tree
  ## placed in its leaf without the cap; `memory` says what is in place and
  ## why the rest is not.
  vanished = false
  memory = MemoryPreparation()
  when defined(linux):
    if not target.placed:
      problem = "no cgroup root"
      return false
    if not ensureDir(target.root, problem, vanished): return false
    if not enableCpuBelow(target.root, problem, vanished): return false
    var memoryOn = false
    if target.memory:
      var memoryProblem = ""
      var gone = false
      memoryOn = enableControllerBelow(target.root, "memory", memoryProblem,
        gone)
      if gone:
        vanished = true
        problem = memoryProblem
        return false
      if not memoryOn:
        memory.problem = "memory controller not enabled: " & memoryProblem
    let dir = target.dirPath
    if not ensureDir(dir, problem, vanished): return false
    if not writeCgroupFile(dir / "cpu.weight", $target.cpuWeight, problem,
        vanished):
      return false
    if not enableCpuBelow(dir, problem, vanished): return false
    if memoryOn:
      var memoryProblem = ""
      var gone = false
      memoryOn = enableControllerBelow(dir, "memory", memoryProblem, gone)
      if gone:
        vanished = true
        problem = memoryProblem
        return false
      if not memoryOn:
        memory.problem = "memory controller not enabled: " & memoryProblem
    memory.controller = memoryOn
    let leaf = target.leafPath
    if target.freshLeaf:
      if not ensureFreshDir(leaf, problem, vanished, memory.leafTaken):
        return false
      memory.leafCreated = true
    elif not ensureDir(leaf, problem, vanished):
      return false
    if target.cpuMax.len > 0:
      if not writeCgroupFile(leaf / "cpu.max", target.cpuMax, problem,
          vanished):
        return false
    if target.hasMemoryLimits:
      if not memoryOn:
        if memory.problem.len == 0:
          memory.problem = "memory controller not enabled"
        memory.problem = "memory cap not applied: " & memory.problem
      elif not writeMemoryLimits(target, memory, vanished):
        problem = memory.problem
        return false
    true
  else:
    problem = "cgroups exist only on Linux"
    false

proc prepareTarget*(target: CgroupTarget; problem: var string;
                    vanished: var bool): bool =
  var memory: MemoryPreparation
  prepareTarget(target, problem, vanished, memory)

proc prepareTarget*(target: CgroupTarget; problem: var string): bool =
  var vanished = false
  prepareTarget(target, problem, vanished)

when defined(linux):
  var O_DIRECTORY {.importc, header: "<fcntl.h>".}: cint
  proc flock(fd: cint; operation: cint): cint {.importc, header: "<sys/file.h>".}
  var
    LOCK_SH {.importc, header: "<sys/file.h>".}: cint
    LOCK_EX {.importc, header: "<sys/file.h>".}: cint

proc lockCgroupRoot*(root: string; exclusive: bool; create = true): cint =
  ## Hold the root's lock: SHARED by a launcher from reading its group's
  ## priority and preparing its leaf until its child is in it, EXCLUSIVE by
  ## a clean-up while it removes empty directories and by `session set
  ## --priority` while it rewrites a group's weight.
  ##
  ## So a clean-up never removes a directory between another launcher's
  ## preparation and its child's join (the group's `shared` leaf is used by
  ## every tree of the group, and empties whenever one ends), and launchers
  ## never wait for each other. And a weight is never overwritten by an
  ## older priority: a launcher reads the priority and writes the weight
  ## inside one shared hold, and `session set` writes only after the daemon
  ## has taken the new priority and only inside an exclusive hold, so any
  ## launcher that read the old priority has written it before the set's
  ## write, and any launcher that reads afterwards reads the new one
  ## (`rewriteGroupWeight`).
  ##
  ## A `flock(2)` on the root directory, which is never removed; it is
  ## created here if missing, unless `create` is false. Returns the
  ## descriptor to pass to `unlockCgroupRoot`, or -1 when the root cannot be
  ## opened or locked: the caller goes on unlocked, and a directory removed
  ## under it is then retried (`openPreparedProcs`).
  ## https://man7.org/linux/man-pages/man2/flock.2.html
  when defined(linux):
    if root.len == 0:
      return -1
    if create:
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

proc waitUntilEmpty*(dir: string; timeoutMillis: int): bool =
  ## Whether `dir`'s subtree holds no process (`cgroup.events` `populated
  ## 0`), waiting up to `timeoutMillis` for that. For a leaf whose tree the
  ## kernel's OOM killer has just killed as a group: the root is reaped,
  ## but the other killed processes may still be exiting, and removing the
  ## leaf now would fail and leave it behind. True at once when the file
  ## cannot be read (nothing to wait for).
  when defined(linux):
    # The monotonic clock: a wall-clock step must not stretch or cut the
    # wait.
    let deadline = getMonoTime() + initDuration(milliseconds = timeoutMillis)
    while true:
      let events = readSmall(dir / "cgroup.events")
      if events.len == 0 or "populated 0" in events:
        return true
      if getMonoTime() >= deadline:
        return false
      sleep(10)
  else:
    true

proc removeEmptyDescendants*(dir: string) =
  ## `rmdir` of every empty cgroup below `dir`, deepest first: the
  ## sub-cgroups a tree made inside its own cap leaf, which would otherwise
  ## keep the leaf (and its group directory) from ever being removed. Only
  ## for a cap leaf, which holds one tree, and only after that tree ended;
  ## the kernel refuses any that still holds a process. Never follows a
  ## symlink (cgroupfs has none) and never leaves `dir`.
  var dirs: seq[string]
  try:
    for path in walkDirRec(dir, yieldFilter = {pcDir},
        followFilter = {pcDir}):
      dirs.add(path)
  except OSError:
    return
  # Deepest first: a child's path is longer than its parent's.
  for i in 0 ..< dirs.len:
    for j in i + 1 ..< dirs.len:
      if dirs[j].len > dirs[i].len:
        swap(dirs[i], dirs[j])
  for path in dirs:
    discard removeEmptyCgroup(path)

proc releaseTarget*(target: CgroupTarget) =
  ## After a tree ended: remove its leaf, then its group (or reclaimed)
  ## directory, each only if empty, under the root's exclusive lock
  ## (`lockCgroupRoot`), so no other launcher is between preparing the leaf
  ## and its child's join. The root is never removed. The caller must not
  ## hold the root's shared lock itself.
  if not target.placed:
    return
  let lock = lockCgroupRoot(target.root, exclusive = true)
  var removed = removeEmptyCgroup(target.leafPath)
  when defined(posix):
    # A cap leaf the kernel refused (EBUSY) may hold only empty
    # sub-cgroups its tree made; remove those and try once more. The walk
    # happens only then, so an ordinary release costs one `rmdir`.
    if not removed and errno == EBUSY and target.isCapLeaf:
      removeEmptyDescendants(target.leafPath)
      removed = removeEmptyCgroup(target.leafPath)
  if removed:
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
        let stale = target.dirPath / path
        when defined(posix):
          if not removeEmptyCgroup(stale) and errno == EBUSY:
            removeEmptyDescendants(stale)
            discard removeEmptyCgroup(stale)
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
                         priority: SessionPriority;
                         current = GroupPrioritySource()): string =
  ## After a group's priority changed (`runquota session set --priority`),
  ## and only after the daemon has taken the change: write the weight in
  ## force to the group's directory, if this user has one now. A group with
  ## no running placed tree has no directory, and the next tree writes the
  ## weight in force when it prepares one, so "absent" is not a problem.
  ## Returns "" when written or absent, otherwise why not.
  ##
  ## UNDER THE ROOT'S EXCLUSIVE LOCK (`lockCgroupRoot`), so it waits for
  ## every launcher between its priority read and its weight write: one
  ## that read the old priority has written it by then, and this write
  ## lands after it. The priority written is read AGAIN under the lock from
  ## `current` (the daemon), falling back to `priority` (the caller's own
  ## update's answer) only when that read fails: of two sets racing to the
  ## lock, the one that wins it second may hold the OLDER answer, and must
  ## still write what the daemon holds now. The root is not created: with
  ## no root there is no directory, and a launcher that creates one later
  ## reads the priority under the lock after this set's update.
  if not root.usable:
    return ""
  let dir = root.path / groupDirName(group)
  when defined(linux):
    if not dirExists(root.path):
      return ""
    let lock = lockCgroupRoot(root.path, exclusive = true, create = false)
    defer: unlockCgroupRoot(lock)
    if not dirExists(dir):
      return ""
    var inForce = priority
    if not current.readNow(inForce):
      inForce = priority
    var problem = ""
    if not writeCgroupFile(dir / "cpu.weight", $cpuWeightFor(inForce),
        problem):
      return problem
    ""
  else:
    ""

proc openPreparedProcs*(target: CgroupTarget; problem: var string;
                        retryable: var bool;
                        memory: var MemoryPreparation): cint =
  ## Prepare `target` and open its leaf's `cgroup.procs` for writing
  ## (close-on-exec), for a forked child to write itself into before it
  ## executes. -1 on failure with `problem` set; `retryable` when the leaf
  ## vanished after it was prepared (another launcher's clean-up removed
  ## it), so preparing it again can succeed. `memory` is what the
  ## preparation did about the target's memory settings (`prepareTarget`);
  ## `memory.leafTaken` asks the caller for another leaf name.
  retryable = false
  memory = MemoryPreparation()
  when defined(linux):
    var vanished = false
    if not prepareTarget(target, problem, vanished, memory):
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

proc openPreparedProcs*(target: CgroupTarget; problem: var string;
                        retryable: var bool): cint =
  var memory: MemoryPreparation
  openPreparedProcs(target, problem, retryable, memory)

proc openLeafDir*(target: CgroupTarget; problem: var string;
                  vanished: var bool): cint =
  ## The leaf's directory, opened `O_RDONLY | O_DIRECTORY | O_CLOEXEC`, for
  ## `clone3(CLONE_INTO_CGROUP)` (clone(2): "cgroup" is a file descriptor
  ## referring to a directory in a cgroup v2 hierarchy). -1 with `problem`
  ## on failure; `vanished` when the leaf was removed meanwhile.
  vanished = false
  when defined(linux):
    let leaf = target.leafPath
    let fd = posix.open(cstring(leaf), O_RDONLY or O_DIRECTORY or O_CLOEXEC)
    if fd < 0:
      let saved = errno
      vanished = removedErrno(saved)
      problem = "cannot open " & leaf & ": " & $strerror(saved)
    fd
  else:
    problem = "cgroups exist only on Linux"
    -1

proc moveIntoTarget*(target: CgroupTarget; pid: int;
                     problem: var string;
                     memory: var MemoryPreparation): bool =
  ## Prepare `target` again and move process `pid` into its leaf: the
  ## parent's half of the vanished-leaf retry, for a child that is waiting,
  ## not yet executed, after its own write found the leaf gone. A leaf the
  ## launch created for itself (`freshLeaf`) is still its own: it was
  ## created once by this launch and vanished, so creating it again here is
  ## the same leaf, not another tree's.
  when defined(linux):
    var again = target
    again.freshLeaf = false
    var vanished = false
    if not prepareTarget(again, problem, vanished, memory):
      return false
    writeCgroupFile(target.leafPath / "cgroup.procs", $pid, problem)
  else:
    problem = "cgroups exist only on Linux"
    false

proc moveIntoTarget*(target: CgroupTarget; pid: int;
                     problem: var string): bool =
  var memory: MemoryPreparation
  moveIntoTarget(target, pid, problem, memory)

proc mountHasLocalEvents*(mountinfo: string;
                          mountPoint = CgroupMountPoint): bool =
  ## Whether the cgroup2 file system at `mountPoint` is mounted with
  ## `memory_localevents`, from `/proc/self/mountinfo` text. That option
  ## makes every `memory.events` count the cgroup alone, like
  ## `memory.events.local` (cgroup-v2.rst, "memory_localevents"). Each
  ## line is `id parent major:minor root mount-point options ... - fstype
  ## source super-options` (proc(5)).
  for line in mountinfo.splitLines():
    let fields = line.splitWhitespace()
    let dash = fields.find("-")
    if fields.len < 5 or dash < 0 or dash + 3 >= fields.len:
      continue
    if fields[4] != mountPoint or fields[dash + 1] != "cgroup2":
      continue
    return "memory_localevents" in fields[dash + 3].split(',')
  false

var localEventsState: int
  ## 0 not read yet, 1 hierarchical `memory.events`, 2 local
  ## (`memory_localevents`): the mount is read once per process.

proc memoryEventsAreLocal*(): bool =
  ## `mountHasLocalEvents` for this process's cgroup2 mount, read once and
  ## cached (two threads that both read it store the same answer).
  when defined(linux):
    var state = atomicLoadN(addr localEventsState, ATOMIC_ACQUIRE)
    if state == 0:
      state = if mountHasLocalEvents(readSmall("/proc/self/mountinfo")): 2
        else: 1
      atomicStoreN(addr localEventsState, state, ATOMIC_RELEASE)
    state == 2
  else:
    false

proc readLeafMemory*(target: CgroupTarget; events: var MemoryEvents;
                     peakBytes: var uint64; peakKnown: var bool;
                     problem: var string;
                     localEventsMount = memoryEventsAreLocal()): bool =
  ## The leaf's counters, read ONCE, after the tree's root was reaped and
  ## before the leaf is removed: `oom` from `memory.events.local`,
  ## `oom_kill` from the hierarchical `memory.events` (`MemoryEvents` says
  ## why each), and `memory.peak`. False with `problem` when the events
  ## cannot be read (no memory controller on the leaf). A kernel before
  ## 5.19 has no `memory.peak`: the events still classify the end, and
  ## `peakKnown` is false, so nothing learns a peak nobody measured.
  events = MemoryEvents()
  peakBytes = 0'u64
  peakKnown = false
  when defined(linux):
    let leaf = target.leafPath
    var text = ""
    var vanished = false
    if not readCgroupFile(leaf / memoryFile("memory.events.local"), text, problem,
        vanished):
      return false
    let local = parseMemoryEvents(text)
    if not local.known:
      problem = "no oom / oom_kill counts in " & leaf / memoryFile("memory.events.local")
      return false
    var hierarchical: MemoryEvents
    if not localEventsMount:
      if not readCgroupFile(leaf / memoryFile("memory.events"), text, problem,
          vanished):
        return false
      hierarchical = parseMemoryEvents(text)
      if not hierarchical.known:
        problem = "no oom / oom_kill counts in " & leaf / "memory.events"
        return false
    else:
      # `memory_localevents`: `memory.events` counts the leaf alone, so the
      # kills inside the tree's leaf are the sum of the leaf's and every
      # sub-cgroup's own counts. A sub-cgroup the tree has already removed
      # took its count with it; the hierarchical file would have kept it.
      hierarchical = local
      try:
        for path in walkDirRec(leaf, yieldFilter = {pcDir},
            followFilter = {pcDir}):
          var sub = ""
          var subProblem = ""
          var subGone = false
          if readCgroupFile(path / "memory.events.local", sub, subProblem,
              subGone):
            let counts = parseMemoryEvents(sub)
            if counts.known:
              hierarchical.oomKill += counts.oomKill
      except OSError:
        discard
    events = MemoryEvents(known: true, oom: local.oom,
      oomKill: hierarchical.oomKill)
    var peakProblem = ""
    if readCgroupFile(leaf / memoryFile("memory.peak"), text, peakProblem,
        vanished):
      try:
        peakBytes = uint64(parseBiggestUInt(text.strip()))
        peakKnown = true
      except ValueError:
        problem = "cannot parse " & leaf / "memory.peak" & ": '" &
          text.strip() & "'"
    else:
      problem = "the peak is not measured: " & peakProblem
    true
  else:
    problem = "cgroups exist only on Linux"
    false

type
  MemoryProbe* = object
    ## Whether `root` can carry memory-capped leaves, found WITHOUT creating
    ## or writing anything (`probeMemory`).
    available*: bool
      ## The memory controller is available to the root (in its
      ## `cgroup.controllers`, or, before the root exists, enabled in its
      ## parent's `cgroup.subtree_control`).
    problem*: string
      ## Why not, or "".
    oomGroupAncestors*: seq[string]
      ## Every cgroup at or above the root, or between the root and its
      ## leaves, with `memory.oom.group` = 1 (trap 1). Must be empty: such a
      ## cgroup turns one tree's host-OOM kill into the kill of everything
      ## below it.

proc readsOne(path: string): bool =
  readSmall(path).strip() == "1"

proc probeMemory*(root: CgroupRoot): MemoryProbe =
  ## The memory half of `probeRoot`, for the capability record: whether the
  ## memory controller reaches the root, and which cgroups that are not
  ## task leaves have `memory.oom.group` set. Reads only.
  if not root.usable:
    result.problem = root.reason
    return
  when defined(linux):
    # The cgroups above the root, from the mount down: a host-wide OOM's
    # domain is the whole hierarchy, so `oom.group` on any of them makes
    # the kernel kill that whole cgroup instead of one tree.
    let relative = root.path[min(root.path.len, CgroupMountPoint.len) .. ^1]
    var dir = CgroupMountPoint
    for component in relative.split('/'):
      if component.len == 0:
        continue
      dir = dir / component
      if dir != root.path and readsOne(dir / "memory.oom.group"):
        result.oomGroupAncestors.add(dir)
    if dirExists(root.path):
      if readsOne(root.path / "memory.oom.group"):
        result.oomGroupAncestors.add(root.path)
      # The group and reclaimed directories: every directory directly below
      # the root is an ancestor of leaves.
      try:
        for kind, path in walkDir(root.path):
          if kind == pcDir and readsOne(path / "memory.oom.group"):
            result.oomGroupAncestors.add(path)
      except OSError:
        discard
      if not hasController(readSmall(root.path / "cgroup.controllers"),
          "memory"):
        result.problem = "the memory controller is not available in " &
          root.path
        return
    else:
      let parent = root.path.parentDir
      if not hasController(readSmall(parent / "cgroup.subtree_control"),
          "memory"):
        result.problem = "the memory controller is not delegated to " &
          parent & " (missing from its cgroup.subtree_control)"
        return
    result.available = true
  else:
    result.problem = "cgroups exist only on Linux"
