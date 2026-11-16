## Where a leased process tree runs below admission on WINDOWS: the Job
## Object priority-class limit RunQuota's launchers put on each tree, the
## Windows analogue of the Linux cgroup `cpu.weight` tiers
## (`cgroup_placement`). Windows has no cgroups, so there is no root to
## resolve, no delegation to probe and no "unavailable" state: a Job Object
## is available on every Windows host this ships for. All that is decided
## here is WHETHER a launcher forces the priority class (the switch) and
## WHICH class a group's priority maps to.
##
## TWO LAYERS, as on Linux. Linux lowers a reclaimed tree by `nice +10`
## UNCONDITIONALLY and, only when cgroup placement is on, ALSO places it at
## `cpu.weight` 1 -- a stronger mechanism layered on top. Windows mirrors
## this: the launcher lowers every reclaimed tree to
## `BELOW_NORMAL_PRIORITY_CLASS` UNCONDITIONALLY (`runquota_process`,
## `CommandSpec.niceIncrement`), and only when THIS switch is on does it ALSO
## force the whole tree -- every process now and every one it later spawns --
## to a priority-class LIMIT on its Job Object, below-admission tiering that a
## child cannot escape for itself. A reclaimed tree is then forced all the way
## down to `IDLE_PRIORITY_CLASS`, stronger than the unconditional below-normal.
##
## OFF BY DEFAULT behind a host switch, by the same manager decision the Linux
## cgroup switch follows: enforcement below admission is not on by default
## until an overhead gate has measured it within budget. The gate is separate,
## later work; this leg ships the mechanism off by default.
##
## Static-helper library rules apply (no `ref` types): this module is part of
## `runquota_process`.

import std/[os, strutils]

import runquota_core

const
  JobPriorityEnvVar* = "RUNQUOTA_JOB_PRIORITY"
    ## `off`: no priority-class limit, whatever the host file says (the `off`
    ## wins over everything, as `RUNQUOTA_CGROUP_ROOT=off` does on Linux).
    ## `on`: force it, an explicit opt-in (for tests and the overhead gate).
    ## Unset or empty: defer to the host file's `[enforcement] job-priority`
    ## (off when absent).
  JobPriorityOn* = "on"
  JobPriorityOff* = "off"

  # The Win32 priority-class constants below realtime (processthreadsapi.h),
  # lowest scheduling priority to highest, onto which the five Linux
  # `cpu.weight` tiers map with no collision. The numeric values are not
  # ordered by priority (they are bit flags); only the mapping below is.
  IdlePriorityClass* = 0x00000040'u32
    ## A reclaimed tree: runs only when nothing else wants the CPU.
  BelowNormalPriorityClass* = 0x00004000'u32
    ## A `low` group (and the unconditional class of a reclaimed tree when
    ## this switch is off).
  NormalPriorityClass* = 0x00000020'u32
    ## A `normal` group: competes evenly with work RunQuota does not place.
  AboveNormalPriorityClass* = 0x00008000'u32
    ## A `high` group.
  HighPriorityClass* = 0x00000080'u32
    ## An `urgent` group (still below realtime, which RunQuota never grants).

proc jobPriorityClassFor*(priority: SessionPriority; reclaimed: bool): uint32 =
  ## The Win32 priority class a tree's Job Object is held to when job-priority
  ## enforcement is on: idle for a RECLAIMED grant whatever its group (it
  ## yields to everything it was admitted beside), otherwise the group's
  ## priority mapped onto the five classes below realtime, each one step above
  ## the one below -- the Windows analogue of the `low 25 / normal 100 /
  ## high 400 / urgent 1600` cgroup weights.
  if reclaimed:
    return IdlePriorityClass
  case priority
  of sessionPriorityLow: BelowNormalPriorityClass
  of sessionPriorityNormal: NormalPriorityClass
  of sessionPriorityHigh: AboveNormalPriorityClass
  of sessionPriorityUrgent: HighPriorityClass

proc resolveJobPriority*(envValue: string; hostSwitchOn: bool): bool =
  ## Whether a launcher forces the Job Object priority class, from the value
  ## of `RUNQUOTA_JOB_PRIORITY` and the host file's `[enforcement]
  ## job-priority` (`hostSwitchOn`). Pure.
  ##
  ## PRECEDENCE, matching what the Linux `resolveCgroupRoot` documents: the
  ## variable's `off` wins over everything; `on` turns it on; unset, empty or
  ## any other value defers to the host switch, and that is off unless the
  ## host file turns it on (enforcement below admission has not passed the
  ## overhead gate; a launcher never fails over a setting it only consults).
  let value = envValue.strip()
  if value == JobPriorityOff:
    return false
  if value == JobPriorityOn:
    return true
  hostSwitchOn

proc currentJobPriorityOn*(hostSwitchOn = false): bool =
  ## `resolveJobPriority` for this process's environment. A library caller
  ## that reads no host file passes nothing, so only `RUNQUOTA_JOB_PRIORITY=on`
  ## turns it on -- mirroring how `currentCgroupRoot` places only when the
  ## variable names a root.
  resolveJobPriority(getEnv(JobPriorityEnvVar), hostSwitchOn)

proc jobPriorityOffReason*(hostSwitchOn: bool): string =
  ## Why job-priority enforcement is off, for the capability record; "" when
  ## it is on. Reads the environment for the `off` override the same way
  ## `resolveJobPriority` does.
  let value = getEnv(JobPriorityEnvVar).strip()
  if value == JobPriorityOff:
    "turned off by " & JobPriorityEnvVar & "=off"
  elif value == JobPriorityOn or hostSwitchOn:
    ""
  else:
    "off by default (the host file does not set [enforcement] " &
      "job-priority = \"on\")"
