## Where a leased process tree runs below admission on MACOS: the process
## priority policy RunQuota's launchers apply to each tree before it executes,
## the macOS analogue of the Linux cgroup `cpu.weight` tiers
## (`cgroup_placement`) and the Windows Job Object priority classes
## (`job_priority`).
##
## WHAT THE OPERATING SYSTEM GIVES A LAUNCHER, MEASURED (Darwin 25, arm64,
## 2026-11-16). A launcher that keeps `fork` + `execve` (so that the fork
## handlers of preload libraries still run; `posix_spawn` and its QoS
## attributes are therefore not available) can set, in the forked child, two
## things that survive the `execve` and are inherited by every process the
## tree starts, and ONE of them changes how the scheduler treats the tree:
##
## * `setpriority(PRIO_DARWIN_PROCESS, 0, PRIO_DARWIN_BG)`: the BACKGROUND
##   policy of the whole process (what `taskpolicy -b` applies). The kernel's
##   own reading of the process afterwards (`proc_pidinfo(PROC_PIDTASKINFO)`
##   `pti_priority`) is 4 against 31 for an unlowered process, and under CPU
##   contention a background tree of 16 exec'd processes took 0.00 CPU-s
##   against 41 for 16 unlowered ones (16 + 16 CPU-bound processes for 3 s on
##   16 CPUs, host load about 50). It also throttles the tree's disk and
##   network IO and its timers.
## * `nice(2)`: the kernel reports it (`pti_priority` 31 -> 21 at +10), but it
##   did NOT change the CPU share of an exec'd tree: nice +10 against nice 0,
##   and nice +15 and +20 against 0, each 16 against 16 exec'd processes,
##   split the CPU 1.00 : 1.00 (+/- 2%); the same comparison between forked
##   spinners that never `execve` gave 15 : 23 at +10. An exec'd process's main
##   thread carries a QoS class, and the scheduler derives its priority from
##   that, not from the task's nice. Nice is therefore applied only where it
##   already was (the reclaimed tree's unconditional +10) and is not counted
##   as enforcement.
##
## What it does NOT give: a QoS CLASS between the default and background, for
## the tree, however it is asked. `pthread_set_qos_class_self_np` in the
## forked child fails (EPERM), and set in the launcher before the `fork` it is
## not inherited across the `execve`; `task_policy_set` of a role or of a
## throughput/latency tier changes nothing observable; the QoS clamp of
## `taskpolicy -c` exists only as a `posix_spawn` attribute (or through
## `taskpolicy` itself, a wrapper that would bypass the fork handlers). Nothing
## raises a tree above the default either: that needs a negative nice, a
## privilege, and nice does not schedule exec'd trees anyway. So macOS has TWO
## levels, not four:
##
## | priority in force      | policy on the tree                    |
## |------------------------|---------------------------------------|
## | reclaimed (any group)  | background policy                     |
## | low                    | background policy                     |
## | normal, high, urgent   | unchanged                             |
##
## `low` is therefore held as hard as reclaimed work (it takes CPU only the
## unlowered work leaves, rather than a share of a quarter as on Linux), and
## `high` and `urgent` are NOT distinguished from `normal`; the capability
## record says both.
##
## TWO LAYERS, as on Linux and Windows. A reclaimed tree keeps its
## UNCONDITIONAL nice +10 (`CommandSpec.niceIncrement`; see above for how
## little that does on macOS); only when this switch is on does the launcher
## apply the background policy to a reclaimed or `low` tree. OFF BY DEFAULT
## behind a host switch, by the same manager decision the cgroup switch
## follows: enforcement below admission is not on by default until the
## overhead gate has passed it.
##
## Static-helper library rules apply (no `ref` types).

import std/[os, strutils]

import runquota_core

const
  QosEnvVar* = "RUNQUOTA_QOS"
    ## `off`: no priority policy beyond the reclaimed nice, whatever the host
    ## file says (`off` wins over everything, as `RUNQUOTA_CGROUP_ROOT=off`
    ## does on Linux). `on`: apply it, an explicit opt-in (for tests and the
    ## overhead gate). Unset or empty: defer to the host file's
    ## `[enforcement] qos` (off when absent).
  QosOn* = "on"
  QosOff* = "off"

  QosTierNone* = 0'u8
    ## Nothing applied by this layer.
  QosTierBackground* = 1'u8
    ## The background policy (`setpriority(PRIO_DARWIN_PROCESS, 0,
    ## PRIO_DARWIN_BG)`): a reclaimed grant's tree and a `low` group's.

proc qosTierFor*(priority: SessionPriority; reclaimed: bool): uint8 =
  ## The tier a tree is held to when the switch is on: background for a
  ## RECLAIMED grant whatever its group (it yields to everything it was
  ## admitted beside) and for a `low` group; nothing for the priorities the
  ## operating system gives an unprivileged launcher no way to raise above
  ## the default.
  if reclaimed:
    return QosTierBackground
  case priority
  of sessionPriorityLow: QosTierBackground
  of sessionPriorityNormal, sessionPriorityHigh, sessionPriorityUrgent:
    QosTierNone

proc qosTierName*(tier: uint8): string =
  ## For a launcher's verbose output.
  case tier
  of QosTierBackground: "background"
  else: "unchanged"

proc resolveQos*(envValue: string; hostSwitchOn: bool): bool =
  ## Whether a launcher applies the priority policy, from the value of
  ## `RUNQUOTA_QOS` and the host file's `[enforcement] qos` (`hostSwitchOn`).
  ## Pure. PRECEDENCE, as `resolveJobPriority` and the cgroup root: the
  ## variable's `off` wins over everything; `on` turns it on; unset, empty or
  ## any other value defers to the host switch, off unless the host file
  ## turns it on.
  let value = envValue.strip()
  if value == QosOff:
    return false
  if value == QosOn:
    return true
  hostSwitchOn

proc currentQosOn*(hostSwitchOn = false): bool =
  ## `resolveQos` for this process's environment. A library caller that reads
  ## no host file passes nothing, so only `RUNQUOTA_QOS=on` turns it on.
  resolveQos(getEnv(QosEnvVar), hostSwitchOn)

proc qosOffReason*(hostSwitchOn: bool): string =
  ## Why the priority policy is off, for the capability record; "" when it is
  ## on.
  let value = getEnv(QosEnvVar).strip()
  if value == QosOff:
    "turned off by " & QosEnvVar & "=off"
  elif value == QosOn or hostSwitchOn:
    ""
  else:
    "off by default (the host file does not set [enforcement] " &
      "qos = \"on\")"
