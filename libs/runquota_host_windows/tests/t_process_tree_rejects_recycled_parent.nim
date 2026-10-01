## Windows process-tree telemetry: the recycled-parent-PID guard.
##
## `collectTreePids` links a process to its parent through Toolhelp32's
## `th32ParentProcessID`, which Windows never clears when the parent exits
## while PIDs are reused — so a stranger whose original parent died can look
## like a child of whatever new process reuses that PID, and a lease's
## measured peak absorbs the stranger's working set. The guard rejects a link
## whose "child" was created BEFORE its "parent".
##
## A recycled pair cannot be forged on demand, so these cases pin the two
## properties that CAN be observed: the guard never drops a genuine child
## (a real child is always younger than its parent), and a tree sample of a
## live process with a live child counts both.

import std/[os, osproc, sets, unittest]

import runquota_host_windows {.all.}

when defined(windows):
  # A real child with a bounded lifetime, independent of shell/PATH setup.
  # The parent observes its OS identity and terminates it after sampling.
  if commandLineParams() == @["--live-child"]:
    sleep(30_000)
    quit(0)

  suite "process tree: recycled parent PIDs":

    test "a genuine child is younger than its parent and is kept":
      let child = startProcess(getAppFilename(), args = ["--live-child"])
      defer:
        try: child.terminate() except CatchableError: discard
        child.close()
      sleep(300)  # let the child appear in a Toolhelp32 snapshot
      let me = uint64(getCurrentProcessId())
      let kid = uint64(child.processID)
      check processCreationMicros(kid) >= processCreationMicros(me)
      let tree = collectTreePids(me)
      check me in tree
      check kid in tree

    test "the tree sample counts the live child":
      let child = startProcess(getAppFilename(), args = ["--live-child"])
      defer:
        try: child.terminate() except CatchableError: discard
        child.close()
      sleep(300)
      let sample = sampleWindowsProcessTreeTelemetry(
        uint64(getCurrentProcessId()))
      check sample.rootAlive
      check sample.processCount >= 2'u32
      check sample.residentMemoryBytes > 0'u64

    test "creation time of a process that does not exist reads as zero":
      # Zero is what makes the guard fall back to the old behaviour instead
      # of rejecting a link it could not evaluate.
      check processCreationMicros(0'u64) == 0'u64
