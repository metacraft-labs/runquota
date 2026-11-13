## The overhead gate's Reprobuild subject: SIXTY-FOUR independent actions.
##
## WHY THIS SHAPE. The gate asks what RunQuota's measurements cost a real
## Reprobuild build, so the subject must exercise everything that runs per
## action under RunQuota -- a lease request, its grant, the launch, the
## launching client's tree sampling while it waits, the finish and the
## daemon's record of it -- and do so often enough that a per-action cost
## shows up in the total. 64 independent actions against a budget of a few
## CPUs keeps the ready set saturated for the whole build, so every action
## is admitted through a queue, as on a loaded host.
##
## WHY A SHELL LOOP AND NOT A COMPILER. Each action burns a fixed amount of
## CPU in the shell itself (`iterations` loop turns, a constant of this
## file), so its cost depends on nothing outside this file:
## no toolchain version, no header cache, no file system state. A compile
## would add variance the gate then has to average away, and the gate
## measures a DIFFERENCE between two arms of the same build, for which a
## stable workload is worth more than a realistic one. The per-action cost
## is a few hundred milliseconds of CPU, so process start-up does not
## dominate, which would flatter the per-action overhead.
##
## `cacheable = false` makes every invocation execute all 64 actions; the
## gate never measures a cache hit.

import std/strutils
import repro_project_dsl
import repro_dsl_stdlib/packages/sh

const
  actionCount = 64
  iterations = 150_000

package overhead_gate_subject:
  defaultToolProvisioning "path"
  uses:
    "sh"
  build:
    for index in 0 ..< actionCount:
      let name = "burn-" & align($index, 2, '0')
      let action = shell(
        command = "i=0; while [ $i -lt " & $iterations &
          " ]; do i=$((i+1)); done; echo $i > " & name & ".txt",
        actionId = "overhead-gate." & name,
        extraOutputs = @[name & ".txt"],
        cacheable = false)
      discard target(name, action)
