## This host's physical memory, on every platform RunQuota runs on.
##
## The built-in memory budget is a share of it (`defaultMemoryBudgetBytes` in
## `runquota_daemon/host_config`), so `defaultDaemonConfig` and `runquota
## config show` both need the number, and need the same number.

when defined(windows):
  import runquota_host_windows
elif defined(macosx):
  import runquota_host_macos
elif defined(linux):
  import runquota_host_linux

proc hostPhysicalMemoryBytes*(): uint64 =
  ## Total physical memory in bytes: `GlobalMemoryStatusEx` on Windows,
  ## `MemTotal` from `/proc/meminfo` on Linux, `hw.memsize` on macOS. 0 when
  ## it cannot be read, which the budget turns into its fallback.
  when defined(windows):
    runquota_host_windows.totalMemory()
  elif defined(macosx):
    runquota_host_macos.totalMemory()
  elif defined(linux):
    runquota_host_linux.totalMemory()
  else:
    0'u64
