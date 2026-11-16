## The macOS priority policy a launcher applies to a leased tree below
## admission (`runquota_process/qos_priority`), and what the capability record
## says about it.
##
## WHAT IS GUARDED, each with the change that makes it fail:
##
## * The mapping of a priority in force onto a tier: reclaimed -> background
##   whatever the group, low -> background, normal / high / urgent -> nothing
##   (macOS gives an unprivileged launcher no way above the default, and
##   nothing between the default and background).
##   Mutation: `qosTierFor` ignoring the group's priority.
## * The switch: the variable's `off` wins, `on` turns it on, empty and any
##   other value defer to the host switch, off unless the host file turns it
##   on. Mutation: ignoring the `off` override.
## * The capability record, in both states (any OS can build it): off,
##   priority is admission-only and reclaimed is degraded, each naming the
##   gap; on, reclaimed is enforced and priority is degraded with the
##   "cannot raise above normal" gap; the width cap and the memory cap are
##   never claimed. Mutation: the on-record claiming priority `enforced`.
## * On macOS, with REAL PROCESSES, what the operating system itself reports
##   of the launched child: `getpriority(PRIO_PROCESS)` (nice),
##   `getpriority(PRIO_DARWIN_PROCESS)` (the background policy: 1) and the
##   kernel's scheduling priority of the task
##   (`proc_pidinfo(PROC_PIDTASKINFO).pti_priority`, 31 for an ordinary
##   process, 4 under the background policy), for each tier; that a
##   grandchild the child starts inherits them; that the launch is still an
##   ordinary `fork` (a `pthread_atfork` child handler of the launcher runs
##   in the forked child); and that the priority is read at the last instant
##   (a stale tier is replaced by the one in force, and a layer that is off
##   stays off). Mutations: the child not applying the background policy;
##   the launch ignoring the last-instant source.
##   (That the policy changes the CPU share is `t_macos_priority_enforcement`'s
##   subject; here it is the readback.)
##
## NO MOCKS: real `fork`/`execve` through `launchProcess`, the OS's own
## readback. The only stand-in is the priority source's answer (a test
## callback in place of the daemon round trip, the same seam
## `t_group_weight_race` uses on Linux).
import std/[os, osproc, strutils, unittest]
import runquota_core
import runquota_process

when defined(macosx):
  import std/posix

  proc getpriority(which: cint; who: cuint): cint {.
    importc, header: "<sys/resource.h>".}
  var PRIO_PROCESS {.importc, header: "<sys/resource.h>".}: cint
  var PRIO_DARWIN_PROCESS {.importc, header: "<sys/resource.h>".}: cint

  type ProcTaskInfo {.importc: "struct proc_taskinfo",
      header: "<libproc.h>".} = object
    pti_priority: int32

  var PROC_PIDTASKINFO {.importc, header: "<libproc.h>".}: cint
  proc procPidinfo(pid: cint; flavor: cint; arg: uint64; buffer: pointer;
                   size: cint): cint {.importc: "proc_pidinfo",
                                       header: "<libproc.h>".}
  proc pthreadAtfork(prepare, parent, child: proc () {.cdecl.}): cint {.
    importc: "pthread_atfork", header: "<pthread.h>".}

  proc ownState(): string =
    ## "<nice> <background 0/1> <kernel scheduling priority>" of this process.
    var info: ProcTaskInfo
    discard procPidinfo(getpid(), PROC_PIDTASKINFO, 0'u64, addr info,
      cint(sizeof(info)))
    $getpriority(PRIO_PROCESS, 0) & " " &
      $getpriority(PRIO_DARWIN_PROCESS, 0) & " " & $info.pti_priority

  if paramCount() >= 1 and paramStr(1) == "--report":
    # The child, and (with `--grandchild`) the process it starts.
    if paramCount() >= 2 and paramStr(2) == "--grandchild":
      let (output, code) = execCmdEx(quoteShell(getAppFilename()) & " --report")
      echo "child " & ownState() & " grandchild " & output.strip()
      quit(code)
    echo ownState()
    quit(0)

  var forkMarker = ""
  proc atforkChild() {.cdecl.} =
    ## Runs in the forked child, before its `execve`, if the launch is an
    ## ordinary `fork` (async-signal-safe: one `open`, one `close`).
    if forkMarker.len > 0:
      let fd = open(cstring(forkMarker), O_WRONLY or O_CREAT, 0o600)
      if fd >= 0: discard close(fd)

  type
    Answer = object
      priority: SessionPriority
      answers: bool

  proc readAnswer(context: pointer; priority: var SessionPriority): bool {.
      nimcall, raises: [].} =
    let answer = cast[ptr Answer](context)
    priority = answer.priority
    answer.answers

  type Observed = object
    nice, background, schedulingPriority: int

  proc parseState(words: seq[string]): Observed =
    Observed(nice: parseInt(words[0]), background: parseInt(words[1]),
      schedulingPriority: parseInt(words[2]))

  proc launchWords(spec: CommandSpec): seq[string] =
    ## Launch this binary in report mode with `spec`; what it printed.
    var child = launchProcess(spec)
    let completion = child.waitForCompletion()
    child.close()
    check completion.exited and completion.exitCode == 0
    completion.stdout.splitWhitespace()

  proc launchObserved(spec: CommandSpec): Observed =
    ## The child's own state, as the kernel reports it.
    parseState(launchWords(spec))

suite "macOS priority tiers":
  test "the mapping from the priority in force":
    for p in SessionPriority:
      check qosTierFor(p, reclaimed = true) == QosTierBackground
    check qosTierFor(sessionPriorityLow, false) == QosTierBackground
    check qosTierFor(sessionPriorityNormal, false) == QosTierNone
    check qosTierFor(sessionPriorityHigh, false) == QosTierNone
    check qosTierFor(sessionPriorityUrgent, false) == QosTierNone
    check qosTierName(QosTierNone) == "unchanged"
    check "background" in qosTierName(QosTierBackground)

  test "the switch resolution":
    check resolveQos("off", hostSwitchOn = true) == false
    check resolveQos("on", hostSwitchOn = false) == true
    check resolveQos("", hostSwitchOn = false) == false
    check resolveQos("", hostSwitchOn = true) == true
    check resolveQos("  off  ", hostSwitchOn = true) == false
    check resolveQos("garbage", hostSwitchOn = true) == true
    check resolveQos("garbage", hostSwitchOn = false) == false

  test "the capability record, off and on":
    let off = enforcementRecordFor("macos")
    check off.os == "macos"
    check off.entries[0].mechanism == emPriority
    check off.entries[0].level == elAdmissionOnly
    check "qos priority off:" in off.entries[0].gap
    check "off by default" in off.entries[0].gap
    check off.entries[1].mechanism == emReclaimed
    check off.entries[1].level == elDegraded
    check "nice +10" in off.entries[1].how
    check off.gaps.len == 4
    let why = enforcementRecordFor("macos", qosOn = false,
      qosProblem = "turned off by RUNQUOTA_QOS=off")
    check "turned off by RUNQUOTA_QOS=off" in why.entries[0].gap
    let on = enforcementRecordFor("macos", qosOn = true)
    check on.entries[0].level == elDegraded
    check "high and urgent cannot be raised above normal" in on.entries[0].gap
    check "a low group is held as hard as reclaimed" in on.entries[0].gap
    check "measured not to change the CPU share" in off.entries[1].gap
    check on.entries[1].level == elEnforced
    check "background policy" in on.entries[1].how
    check on.entries[1].gap.len == 0
    # Never claimed on macOS, in either state.
    for record in [off, on]:
      check record.entries[2].mechanism == emWidthCap
      check record.entries[2].level == elNone
      check "no hard CPU cap" in record.entries[2].gap
      check record.entries[3].mechanism == emMemoryCap
      check record.entries[3].level == elNone
    check on.gaps.len == 3
    check "priority=degraded" in on.summaryLine
    check "reclaimed=enforced" in on.summaryLine
    check "macOS has no hard CPU cap" in on.summaryLine

when defined(macosx):
  suite "macOS priority policy of a launched tree (the OS's own readback)":
    test "each tier, read back from the kernel, and inherited by a grandchild":
      let none = launchObserved(commandSpec([getAppFilename(), "--report"]))
      var bgSpec = commandSpec([getAppFilename(), "--report"])
      bgSpec.qosTier = QosTierBackground
      let background = launchObserved(bgSpec)
      echo "kernel scheduling priority: unchanged " & $none.schedulingPriority &
        ", background " & $background.schedulingPriority
      check none.background == 0
      check background.background == 1
      check background.schedulingPriority < none.schedulingPriority
      check background.nice == none.nice   # the tier adds no nice
      # The grandchild: the child starts a process of its own.
      var tree = commandSpec([getAppFilename(), "--report", "--grandchild"])
      tree.qosTier = QosTierBackground
      let words = launchWords(tree)
      check words.len == 8
      check words[0] == "child" and words[4] == "grandchild"
      check parseState(words[1 .. 3]).background == 1
      let grand = parseState(words[5 .. 7])
      check grand.background == 1
      check grand.schedulingPriority == background.schedulingPriority

    test "the launch is an ordinary fork: the launcher's fork handlers run":
      forkMarker = getTempDir() / ("rq-atfork-" & $getpid())
      check pthreadAtfork(nil, nil, atforkChild) == 0
      var spec = commandSpec([getAppFilename(), "--report"])
      spec.qosTier = QosTierBackground
      let observed = launchObserved(spec)
      check observed.background == 1
      check fileExists(forkMarker)
      removeFile(forkMarker)
      forkMarker = ""

    test "the tier is read at the last instant":
      let none = launchObserved(commandSpec([getAppFilename(), "--report"]))
      # Placement said `low` (background), the daemon now says `high`: nothing.
      var answer = Answer(priority: sessionPriorityHigh, answers: true)
      var spec = commandSpec([getAppFilename(), "--report"])
      spec.qosTier = QosTierBackground
      spec.cgroupPriority = GroupPrioritySource(read: readAnswer,
        context: addr answer)
      let raised = launchObserved(spec)
      check raised.background == 0
      check raised.schedulingPriority == none.schedulingPriority
      # The layer is on (a tier was resolved) and the daemon now says `low`.
      answer.priority = sessionPriorityLow
      check launchObserved(spec).background == 1
      # A daemon that cannot answer keeps the placement's tier.
      answer.priority = sessionPriorityHigh
      answer.answers = false
      check launchObserved(spec).background == 1
      # The layer OFF stays off whatever the source says.
      answer.priority = sessionPriorityLow
      answer.answers = true
      spec.qosTier = QosTierNone
      check launchObserved(spec).background == 0

    test "a reclaimed nice is kept beside the tier":
      let none = launchObserved(commandSpec([getAppFilename(), "--report"]))
      var spec = commandSpec([getAppFilename(), "--report"])
      spec.niceIncrement = 10
      spec.qosTier = QosTierBackground
      let observed = launchObserved(spec)
      check observed.nice == none.nice + 10
      check observed.background == 1
