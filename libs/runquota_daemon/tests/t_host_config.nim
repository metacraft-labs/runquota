## The per-host budget file (`host_config`): what it accepts, what it refuses,
## and how it overlays the built-in defaults.
##
## The daemon is host-wide, so whichever process starts it sets the budget for
## every workspace on the host. Observed on a 125.6 GiB Windows workstation: the
## only daemon had been auto-spawned by another workspace with
## `--memory-bytes 17179869184`, and refused a provider compile. The budget now
## comes from `hostConfigPath`. These cases pin the reader's contract: the
## documented subset is read exactly, everything else is refused with the file
## and line (a half-read budget file looks configured and is not), and a missing
## file is the empty configuration.

import std/[options, os, strutils, tables, unittest]

import runquota_core
import runquota_daemon
import runquota_daemon/host_config
import runquota_daemon/host_memory
import runquota_ipc

const sample = """
# Budget for this workstation.
schema = "runquota.host-config.v1"

[machine]
memory_bytes = 103_079_215_104   # 96 GiB
cpu_milli    = 16000

[pools]
compile = 8
fetch   = 2
"""

proc refusal(text: string): string =
  try:
    discard parseHostConfig(text, "host.toml")
  except HostConfigError as err:
    return err.msg
  checkpoint "accepted: " & text
  fail()

suite "host config":
  test "reads the documented shape":
    let host = parseHostConfig(sample, "host.toml")
    check host.memoryBytes == some(103_079_215_104'u64)
    check host.cpuMilli == some(16000'u64)
    check host.pools["compile"] == 8'u32
    check host.pools["fetch"] == 2'u32
    check host.sourcePath == "host.toml"

  test "every key is optional":
    let host = parseHostConfig("schema = \"runquota.host-config.v1\"\n",
      "host.toml")
    check host.memoryBytes.isNone
    check host.cpuMilli.isNone
    check host.pools.len == 0

  test "refuses what it does not model, naming file and line":
    check refusal("schema = \"runquota.host-config.v2\"\n").contains(
      "host.toml:1:")
    check refusal("[machine]\nmemory = 5\n").contains("host.toml:2:")
    check refusal("[network]\n").contains("unknown table")
    check refusal("[[machine]]\n").contains("unsupported table header")
    check refusal("colour = 1\n").contains("unknown top-level key")
    check refusal("[machine]\nmemory_bytes = 1.5e9\n").contains("integer")
    check refusal("[machine]\nmemory_bytes = -1\n").contains("integer")
    check refusal("[machine]\nmemory_bytes = 0x10\n").contains("integer")
    check refusal("[machine]\nmemory_bytes = 1__0\n").contains("integer")
    check refusal("[machine]\nmemory_bytes = 0\n").contains("positive")
    check refusal("[machine]\nmemory_bytes\n").contains("key = value")
    check refusal("[pools]\ncompile = 4294967296\n").contains("out of range")
    check refusal("[machine]\ncpu_milli = 4294967296\n").contains(
      "out of range")
    check refusal("[pools]\ncompile = [1, 2]\n").contains("integer")
    check refusal("[pools]\ncompile = 0\n").contains("positive")

  test "a missing file is the empty configuration, and is not created":
    let dir = getTempDir() / "runquota-t-host-config-missing"
    removeDir(dir)
    let host = readHostConfig(dir / "runquotad.toml")
    check host.memoryBytes.isNone
    check host.cpuMilli.isNone
    check host.pools.len == 0
    check host.sourcePath == ""
    check not dirExists(dir)

  test "reads a file from disk":
    let dir = getTempDir() / "runquota-t-host-config-present"
    removeDir(dir)
    createDir(dir)
    writeFile(dir / "runquotad.toml", sample)
    let host = readHostConfig(dir / "runquotad.toml")
    check host.memoryBytes == some(103_079_215_104'u64)
    check host.sourcePath == dir / "runquotad.toml"
    removeDir(dir)

  test "overlays set keys onto the defaults and leaves the rest":
    var config = defaultDaemonConfig(defaultEndpoint())
    let cpuBefore = config.cpuSlots
    config.applyHostConfig(parseHostConfig(
      "[machine]\nmemory_bytes = 103079215104\n[pools]\ncompile = 3\n",
      "host.toml"))
    check uint64(config.memoryBytes) == 103_079_215_104'u64
    check uint32(config.cpuSlots) == uint32(cpuBefore)
    check config.namedPoolCaps["compile"] == 3'u32

  test "an empty host file changes nothing":
    let pristine = defaultDaemonConfig(defaultEndpoint())
    var config = pristine
    config.applyHostConfig(readHostConfig(
      getTempDir() / "runquota-t-host-config-none" / "runquotad.toml"))
    check uint64(config.memoryBytes) == uint64(pristine.memoryBytes)
    check uint32(config.cpuSlots) == uint32(pristine.cpuSlots)
    check config.namedPoolCaps.len == pristine.namedPoolCaps.len

suite "host config: the built-in memory budget":
  test "is 75% of physical memory":
    check DefaultMemoryBudgetPercent == 75'u64
    check defaultMemoryBudgetBytes(128'u64 * 1024'u64 * 1024'u64 * 1024'u64) ==
      96'u64 * 1024'u64 * 1024'u64 * 1024'u64
    check defaultMemoryBudgetBytes(8'u64 * 1024'u64 * 1024'u64 * 1024'u64) ==
      6'u64 * 1024'u64 * 1024'u64 * 1024'u64
    # Not a multiple of 100: the remainder is carried, not dropped.
    check defaultMemoryBudgetBytes(1001'u64) == 750'u64
    check defaultMemoryBudgetBytes(high(uint64)) > high(uint64) div 4'u64 * 2'u64

  test "falls back to the old constant only when memory cannot be read":
    check defaultMemoryBudgetBytes(0'u64) == FallbackMemoryBudgetBytes
    check FallbackMemoryBudgetBytes == 17_179_869_184'u64

  test "is what defaultDaemonConfig uses on this host":
    let physical = hostPhysicalMemoryBytes()
    # Every platform RunQuota runs on reads it; a 0 here is a broken backend.
    check physical > 0'u64
    let config = defaultDaemonConfig(defaultEndpoint())
    check uint64(config.memoryBytes) == defaultMemoryBudgetBytes(physical)
    check uint64(config.builtinMemoryBytes) == uint64(config.memoryBytes)
    check uint64(config.memoryBytes) < physical

suite "host config: editing":
  proc edited(text, key, value: string; unset = false): string =
    let dir = getTempDir() / ("runquota-t-host-config-edit-" &
      $getCurrentProcessId())
    removeDir(dir)
    createDir(dir)
    defer: removeDir(dir)
    writeFile(dir / "runquotad.toml", text)
    var changed = false
    editHostConfig(dir / "runquotad.toml", key, value, unset, changed)

  test "set replaces the key's line and keeps every other line":
    let after = edited(sample, "machine.memory_bytes", "64GiB")
    check "memory_bytes = 68719476736   # 64 GiB" in after
    check "103_079_215_104" notin after
    check "# Budget for this workstation." in after
    check "cpu_milli    = 16000" in after
    let host = parseHostConfig(after, "t")
    check host.memoryBytes == some(68_719_476_736'u64)
    check host.pools["fetch"] == 2'u32

  test "set adds a key to its table, and a table the file lacks":
    let after = edited("schema = \"runquota.host-config.v1\"\n[machine]\n" &
      "cpu_milli = 4000\n", "pools.link", "2")
    let host = parseHostConfig(after, "t")
    check host.pools["link"] == 2'u32
    check host.cpuMilli == some(4000'u64)
    let more = edited(after, "machine.memory_bytes", "1000")
    let host2 = parseHostConfig(more, "t")
    check host2.memoryBytes == some(1000'u64)
    # Added inside [machine], not after [pools].
    check more.find("memory_bytes") < more.find("[pools]")

  test "unset removes the key and nothing else":
    let after = edited(sample, "pools.compile", "", unset = true)
    let host = parseHostConfig(after, "t")
    check not host.pools.hasKey("compile")
    check host.pools["fetch"] == 2'u32
    check host.memoryBytes == some(103_079_215_104'u64)

  test "refuses what the daemon would refuse, before writing anything":
    for (key, value) in [("machine.memory", "1"), ("network.x", "1"),
                         ("machine.memory_bytes", "0"),
                         ("machine.memory_bytes", "-1"),
                         ("machine.memory_bytes", "1.5GiB"),
                         ("machine.cpu_milli", "4294967296"),
                         ("pools.a b", "1"), ("pools.compile", "0")]:
      var refused = false
      try:
        discard edited(sample, key, value)
      except HostConfigError:
        refused = true
      checkpoint key & " = " & value
      check refused

  test "an absent file starts from the template, which changes no budget":
    let host = parseHostConfig(HostConfigTemplate, "t")
    check host.memoryBytes.isNone
    check host.cpuMilli.isNone
    check host.pools.len == 0
    let dir = getTempDir() / ("runquota-t-host-config-new-" &
      $getCurrentProcessId())
    removeDir(dir)
    createDir(dir)
    defer: removeDir(dir)
    var changed = false
    let text = editHostConfig(dir / "runquotad.toml", "machine.cpu_milli",
      "12000", false, changed)
    check changed
    check "# RunQuota host budget." in text
    check parseHostConfig(text, "t").cpuMilli == some(12000'u64)
    # Computing the edit wrote nothing.
    check not fileExists(dir / "runquotad.toml")

  test "writes atomically, and never creates the directory":
    let dir = getTempDir() / ("runquota-t-host-config-write-" &
      $getCurrentProcessId())
    removeDir(dir)
    expect HostConfigError:
      writeHostConfigAtomically(dir / "runquotad.toml", sample)
    check not dirExists(dir)
    createDir(dir)
    defer: removeDir(dir)
    writeHostConfigAtomically(dir / "runquotad.toml", sample)
    check readFile(dir / "runquotad.toml") == sample
    writeHostConfigAtomically(dir / "runquotad.toml", HostConfigTemplate)
    check readFile(dir / "runquotad.toml") == HostConfigTemplate
    # No temporary file is left beside it.
    var entries = 0
    for _ in walkDir(dir):
      inc entries
    check entries == 1
