## A kernel without `memory.peak` (before Linux 5.19): a cap kill is still
## classified, from the leaf's event counters alone, and the peak is
## reported as not measured.
##
## WHAT IS GUARDED: a tree that passes its cap is `capKilled` with
## `memoryCapMeasured`, a peak of 0 and peak source `mpsNone` (so nothing
## learns a peak the kernel did not give). Mutation: failing the whole read
## when `memory.peak` is missing -- the kill then reads as a plain SIGKILL.
##
## THE ONE STAND-IN, and why: no kernel this old is available to the suite,
## so this binary is compiled (`t_memory_cap_no_peak.nims`) with the
## launcher looking for `memory.peak` under a name that does not exist, and
## the read fails with ENOENT exactly as on such a kernel. Everything else
## is the real launcher, real processes and real cgroups of a test-owned
## root.
import std/[os, posix, strutils, unittest]
import runquota_core
import runquota_process
when defined(linux):
  import cgroup_test_root

when defined(linux):
  var MAP_ANONYMOUS_FLAG {.importc: "MAP_ANONYMOUS", header: "<sys/mman.h>".}: cint

  if paramCount() >= 2 and paramStr(1) == "--alloc":
    let size = parseInt(paramStr(2)) * 1024 * 1024
    let base = mmap(nil, size, PROT_READ or PROT_WRITE,
      MAP_PRIVATE or MAP_ANONYMOUS_FLAG, -1, 0)
    if base == MAP_FAILED:
      quit(3)
    let bytes = cast[ptr UncheckedArray[byte]](base)
    var i = 0
    while i < size:
      bytes[i] = 1
      i += 4096
    quit(0)

  suite "a kernel without memory.peak":
    var reason = ""
    let root = delegatedMemoryTestRoot(reason)

    test "a cap kill is classified from the events, the peak unknown":
      if root.len == 0:
        echo "SKIPPED: " & reason
        skip()
      else:
        var spec = commandSpec([getAppFilename(), "--alloc", "96"])
        spec.cgroup = targetFor(CgroupRoot(state: crsExplicit, path: root),
          "no-peak", sessionPriorityNormal, reclaimed = false)
        spec.memoryCapBytes = 32'u64 shl 20
        spec.memoryCapAction = mcaKill
        var child = launchProcess(spec)
        check child.info.memoryCapApplied
        let completion = child.waitForCompletion(30_000)
        child.close()
        checkpoint "exit " & $completion.exitCode & " signal " & $completion.signal & " " & completion.stderr
        check completion.signaled
        check completion.memoryCapMeasured
        check completion.capKilled
        check completion.memoryPeakBytes == 0
        check completion.memoryPeakSource == mpsNone
        check removeTestRoot(root) == ""
