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
