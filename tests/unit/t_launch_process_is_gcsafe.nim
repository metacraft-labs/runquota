## `launchProcess` stays callable from GC-safe code.
##
## WHY. Consumers call the launcher from `{.gcsafe.}` code -- a thread
## procedure, or a callback typed `gcsafe` -- and Nim refuses to compile
## such a caller as soon as anything `launchProcess` reaches is not GC-safe.
## An indirect call through a procedure type that is not declared `gcsafe`
## is enough: the group-priority reader the launch calls to pick a cgroup
## weight was once such a type, and a downstream build broke on it while
## this repository's own suite, which never calls the launcher from GC-safe
## code, stayed green. This file is that caller.
##
## FALSIFYING MUTATION: dropping `gcsafe` from
## `cgroup_placement.GroupPriorityRead` makes this file fail to compile
## ("'launchFromGcSafeCode' is not GC-safe as it calls 'launchProcess'").
##
## No mocks: nothing is launched; compiling the callers is the test.

import std/unittest

import runquota_process
import runquota_process/cgroup_placement
import runquota_core

proc launchFromGcSafeCode(spec: CommandSpec): LaunchedProcess {.gcsafe.} =
  launchProcess(spec)

proc readPriorityFromGcSafeCode(source: GroupPrioritySource;
                                priority: var SessionPriority): bool {.
    gcsafe.} =
  source.readNow(priority)

suite "launch_process_is_gcsafe":
  test "the launcher and the priority read are callable from GC-safe code":
    # Taking the procedures' addresses keeps them from being dropped as
    # unused; the property itself was checked when this file compiled.
    let launcher: proc (spec: CommandSpec): LaunchedProcess {.gcsafe.} =
      launchFromGcSafeCode
    let reader: proc (source: GroupPrioritySource;
                      priority: var SessionPriority): bool {.gcsafe.} =
      readPriorityFromGcSafeCode
    check not launcher.isNil
    check not reader.isNil
    var priority: SessionPriority
    check not readPriorityFromGcSafeCode(GroupPrioritySource(), priority)
