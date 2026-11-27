## The systemd unit that encloses a cgroup root, and whether it is safe to
## run memory-capped task leaves below it -- read for `runquota status`,
## never on the launch path.
##
## WHY THE UNIT MATTERS. A memory cap kills a tree inside its own leaf. But
## systemd watches the hierarchical `memory.events` of each unit's cgroup,
## which counts an OOM kill ANYWHERE below the unit, and when the unit's
## own `memory.oom.group` is unset it reacts to such a kill by applying the
## unit's `OOMPolicy=`: `stop` (or `kill`) would stop the whole unit -- for
## the default root that is the caller's whole user manager,
## `user@<uid>.service` -- because one task exceeded its cap. A unit with
## `Delegate=yes` defaults its `OOMPolicy=` to `continue`, which leaves the
## unit alone. So the unit enclosing the root must keep `Delegate=yes` and
## must not set `OOMPolicy=stop` or `kill`. See systemd.service(5)
## (`OOMPolicy=`), systemd.resource-control(5) (`Delegate=`) and
## https://systemd.io/CGROUP_DELEGATION/
##
## The rules are pure (`enclosingUnit`, `parseUnitPolicy`,
## `memoryCapUnsafeReason`); only `queryUnitPolicy` runs `systemctl show`.

import std/[monotimes, os, osproc, streams, strutils, times]

type
  EnclosingUnit* = object
    name*: string
      ## The nearest `.service` or `.scope` above the root; "" when none.
    userManager*: bool
      ## The unit belongs to a user's service manager (it is below a
      ## `user@<uid>.service`), so it is shown with `systemctl --user`.

  UnitPolicy* = object
    known*: bool
      ## `systemctl show` answered with both properties.
    delegate*: string
    oomPolicy*: string
    problem*: string
      ## Why the policy is not known, or "".

const
  CgroupMount = "/sys/fs/cgroup"
  SystemctlTimeoutMillis* = 5_000

proc isUnitName(component: string): bool =
  component.endsWith(".service") or component.endsWith(".scope")

proc enclosingUnit*(rootPath: string): EnclosingUnit =
  ## The unit whose cgroup contains `rootPath` (a cgroup directory, absolute
  ## under the cgroup v2 mount): the deepest `.service` or `.scope`
  ## component strictly above the root itself. The default root,
  ## `.../user@<uid>.service/runquota.slice`, is enclosed by the system
  ## manager's `user@<uid>.service`; an explicit root below a unit of the
  ## user's own manager by that unit.
  var relative = rootPath
  if relative.startsWith(CgroupMount):
    relative = relative[CgroupMount.len .. ^1]
  var components: seq[string]
  for component in relative.split('/'):
    if component.len > 0:
      components.add(component)
  if components.len < 2:
    return
  var at = -1
  for i in countdown(components.len - 2, 0):
    if isUnitName(components[i]):
      at = i
      break
  if at < 0:
    return
  result.name = components[at]
  for i in 0 ..< at:
    if components[i].startsWith("user@") and
        components[i].endsWith(".service"):
      result.userManager = true

proc enclosingUnits*(rootPath: string): seq[EnclosingUnit] =
  ## Every `.service` / `.scope` above `rootPath`, deepest first, up to and
  ## including `user@<uid>.service` (above it there are only slices). Each
  ## is a unit systemd watches, and any of them with a bad policy could be
  ## stopped by a cap kill below it, so every one is checked, not only the
  ## nearest.
  var relative = rootPath
  if relative.startsWith(CgroupMount):
    relative = relative[CgroupMount.len .. ^1]
  var components: seq[string]
  for component in relative.split('/'):
    if component.len > 0:
      components.add(component)
  for i in countdown(components.len - 2, 0):
    if not isUnitName(components[i]):
      continue
    var unit = EnclosingUnit(name: components[i])
    for j in 0 ..< i:
      if components[j].startsWith("user@") and
          components[j].endsWith(".service"):
        unit.userManager = true
    result.add(unit)

proc parseUnitPolicy*(output: string): UnitPolicy =
  ## `Delegate=` and `OOMPolicy=` from `systemctl show -p Delegate -p
  ## OOMPolicy` output.
  var haveDelegate, havePolicy = false
  for line in output.splitLines():
    if line.startsWith("Delegate="):
      result.delegate = line["Delegate=".len .. ^1].strip()
      haveDelegate = true
    elif line.startsWith("OOMPolicy="):
      result.oomPolicy = line["OOMPolicy=".len .. ^1].strip()
      havePolicy = true
  result.known = haveDelegate and havePolicy
  if not result.known:
    result.problem = "systemctl show did not report Delegate and OOMPolicy"

proc memoryCapUnsafeReason*(policy: UnitPolicy): string =
  ## "" when memory-capped leaves are safe below a unit with `policy`;
  ## otherwise why not. Unknown is not safe: nothing says it is.
  if not policy.known:
    return "the unit's Delegate and OOMPolicy are unknown (" &
      policy.problem & ")"
  var reasons: seq[string]
  if policy.delegate != "yes":
    reasons.add("Delegate=" & policy.delegate & " (must be yes)")
  if policy.oomPolicy in ["stop", "kill"]:
    reasons.add("OOMPolicy=" & policy.oomPolicy &
      " (must not be stop or kill)")
  reasons.join(", ")

proc queryUnitPolicy*(unit: EnclosingUnit;
                      timeoutMillis = SystemctlTimeoutMillis;
                      systemctl = ""): UnitPolicy =
  ## `systemctl [--user] show <unit> -p Delegate -p OOMPolicy`, bounded by
  ## `timeoutMillis` (a hung bus must not hang `runquota status`): polled
  ## on the monotonic clock, and killed and reaped when it runs out.
  ## `systemctl` names the program; "" finds it on PATH.
  if unit.name.len == 0:
    return UnitPolicy(problem: "no enclosing service or scope unit")
  let program = if systemctl.len > 0: systemctl else: findExe("systemctl")
  if program.len == 0:
    return UnitPolicy(problem: "systemctl is not on PATH")
  var args: seq[string]
  if unit.userManager:
    args.add("--user")
  args.add(["show", unit.name, "-p", "Delegate", "-p", "OOMPolicy"])
  var process: Process
  try:
    process = startProcess(program, args = args,
      options = {poStdErrToStdOut})
  except OSError as error:
    return UnitPolicy(problem: "cannot run systemctl: " & error.msg)
  defer: process.close()
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMillis)
  var code = -1
  try:
    while true:
      code = process.peekExitCode()
      if code != -1:
        break
      if getMonoTime() >= deadline:
        process.kill()
        discard process.waitForExit()
        return UnitPolicy(problem: "systemctl show did not answer within " &
          $timeoutMillis & " ms")
      sleep(10)
    # The answer is two short lines, so it fits the pipe and nothing
    # blocked on reading it while the loop waited.
    let output = process.outputStream.readAll()
    if code != 0:
      return UnitPolicy(problem: "systemctl show exited " & $code & ": " &
        output.strip())
    parseUnitPolicy(output)
  except OSError, IOError:
    UnitPolicy(problem: "cannot read systemctl's answer: " &
      getCurrentExceptionMsg())

proc unitPolicyLines*(unit: EnclosingUnit; policy: UnitPolicy): seq[string] =
  ## `runquota status` text: the unit and its policy, then a
  ## `memory_cap_unsafe:` line when the cap is not safe below it.
  let name = if unit.name.len > 0: unit.name else: "(none)"
  if policy.known:
    result.add("memory_cap_unit: " & name &
      (if unit.userManager: " (user manager)" else: "") &
      " delegate=" & policy.delegate & " oom_policy=" & policy.oomPolicy)
  else:
    result.add("memory_cap_unit: " & name & " unknown (" & policy.problem &
      ")")
  let unsafe = memoryCapUnsafeReason(policy)
  if unsafe.len > 0:
    result.add("memory_cap_unsafe: " & unsafe & "; systemd applies the " &
      "OOMPolicy of " & name & " to an OOM kill anywhere below it, so one " &
      "task's cap kill could stop the whole unit; keep the memory cap " &
      "(and placement) off on this host until the unit is repaired")
