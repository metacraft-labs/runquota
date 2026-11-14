## The pure parts of `runquota jobserver` and of the sub-lease wire form:
## token arithmetic, the `MAKEFLAGS` the command receives, the width flags
## removed from make and ninja, joining an inherited bridge, `--mem` sizes,
## `RUNQUOTA_PARENT_LEASE` parsing and the `RequestSubLease` codec.
##
## NO MOCKS: every case is a value in and a value out. The behaviour against
## real tools and a real daemon is in `tests/integration/t_jobserver_command.nim`
## and `tests/integration/t_sub_lease_admission.nim`.
import std/[options, os, strutils, unittest]

import runquota_client
import runquota_core
import runquota_protocol
import runquota_cli_support/jobserver_command

suite "token arithmetic":
  test "an N-slot grant serves N - 1 tokens; the command holds the Nth":
    check tokensForSlots(1) == 0
    check tokensForSlots(2) == 1
    check tokensForSlots(4) == 3
    check tokensForSlots(16) == 15
    check tokensForSlots(0) == 0

suite "MAKEFLAGS for the command":
  test "the bridge's jobserver replaces any inherited one and any count":
    check bridgeMakeflags("", 4, "/t/fifo") ==
      " -j4 --jobserver-auth=fifo:/t/fifo"
    check bridgeMakeflags(" -k -j9 --jobserver-auth=fifo:/old", 2, "/t/f") ==
      " -k -j2 --jobserver-auth=fifo:/t/f"
    check bridgeMakeflags("ks --jobserver-fds=3,4 -j --jobs=3", 3, "/f") ==
      " ks -j3 --jobserver-auth=fifo:/f"
    check bridgeMakeflags("--jobserver-auth=5,6", 1, "/f") ==
      " -j1 --jobserver-auth=fifo:/f"

  test "the FIFO a MAKEFLAGS names, and joining an inherited bridge":
    check fifoNamedByMakeflags(" -j4 --jobserver-auth=fifo:/a/b") == "/a/b"
    check fifoNamedByMakeflags(" -j4 --jobserver-auth=3,4") == ""
    check fifoNamedByMakeflags("") == ""
    check joinsInheritedBridge(" -j4 --jobserver-auth=fifo:/a/b", "/a/b")
    # A tool in between started a jobserver of its own: not ours to join.
    check not joinsInheritedBridge(" -j4 --jobserver-auth=fifo:/x", "/a/b")
    check not joinsInheritedBridge(" -j4 --jobserver-auth=fifo:/a/b", "")
    check not joinsInheritedBridge("", "/a/b")

suite "explicit widths that would override the jobserver":
  proc stripped(line: string): string =
    var removed: seq[string] = @[]
    stripWidthFlags(line.splitWhitespace(), removed).join(" ")

  test "make and ninja lose -j in every spelling":
    check stripped("make -j") == "make"
    check stripped("make -j8 all") == "make all"
    check stripped("make -j 8 all") == "make all"
    check stripped("make -j all") == "make all"
    check stripped("make --jobs=4 -k") == "make -k"
    check stripped("make --jobs 4") == "make"
    check stripped("gmake -j3") == "gmake"
    check stripped("/usr/bin/make -j3 x") == "/usr/bin/make x"
    check stripped("ninja -j 8 -C build") == "ninja -C build"
    check stripped("ninja -j8") == "ninja"

  test "nothing else is touched":
    check stripped("cargo build -j 8") == "cargo build -j 8"
    check stripped("make -k -C dir") == "make -k -C dir"
    check stripped("make -- -j8") == "make -- -j8"
    check stripped("make -jx") == "make -jx"
    check stripped("make") == "make"

suite "arguments":
  test "--mem sizes":
    var value = 0'u64
    check parseMemorySize("1024", value) and value == 1024'u64
    check parseMemorySize("2GiB", value) and value == 2'u64 shl 30
    check parseMemorySize("512MiB", value) and value == 512'u64 shl 20
    check parseMemorySize("3K", value) and value == 3072'u64
    check not parseMemorySize("0", value)
    check not parseMemorySize("", value)
    check not parseMemorySize("1.5GiB", value)
    check not parseMemorySize("GiB", value)
    check not parseMemorySize("-1", value)

  test "the verb's arguments":
    var options: JobserverOptions
    var error = ""
    check parseJobserverArgs(@["--width", "2:6", "--mem", "1GiB",
      "--stats-key", "k", "--", "cargo", "build"], options, error)
    check options.minWidth == 2 and options.preferredWidth == 6
    check options.memoryGiven and options.memoryBytes == 1'u64 shl 30
    check options.statsKey == "k"
    check options.command == @["cargo", "build"]
    check not parseJobserverArgs(@["--width", "0", "--", "x"], options, error)
    check not parseJobserverArgs(@["--mem", "0", "--", "x"], options, error)
    check not parseJobserverArgs(@["--", ], options, error)
    check not parseJobserverArgs(@["--what", "--", "x"], options, error)

suite "RUNQUOTA_PARENT_LEASE":
  test "a positive decimal lease id, anything else is absent":
    for (text, want) in [("12", 12'u64), (" 7 ", 7'u64),
        ("18446744073709551615", high(uint64))]:
      putEnv(ParentLeaseEnvVar, text)
      let parsed = parentLeaseFromEnvironment()
      check parsed.isSome and parsed.get().value == want
    for text in ["", "0", "-3", "abc", "12a", "18446744073709551616",
        "123456789012345678901"]:
      putEnv(ParentLeaseEnvVar, text)
      check parentLeaseFromEnvironment().isNone
    delEnv(ParentLeaseEnvVar)
    check parentLeaseFromEnvironment().isNone

suite "RequestSubLease wire form":
  test "round trip, and the minor that announces it":
    let msg = RequestSubLeaseMessage(sessionId: sessionId(3),
      parentLeaseId: leaseId(41), clientCandidateId: 9, label: "jobserver x",
      commandStatsId: "run/cargo@p", cpuMinMilli: 1000,
      cpuPreferredMilli: 4000, memoryBytes: 0)
    var decoded: RequestSubLeaseMessage
    check decodeRequestSubLease(encodeRequestSubLease(msg), decoded)
    check decoded.sessionId.value == 3'u64
    check decoded.parentLeaseId.value == 41'u64
    check decoded.clientCandidateId == 9'u64
    check decoded.label == "jobserver x"
    check decoded.commandStatsId == "run/cargo@p"
    check decoded.cpuMinMilli == 1000'u32
    check decoded.cpuPreferredMilli == 4000'u32
    check decoded.memoryBytes == 0'u64
    check not decodeRequestSubLease(encodeRequestSubLease(msg) & "x", decoded)
    check not decodeRequestSubLease(
      encodeRequestSubLease(msg)[0 .. ^2], decoded)
    var kind: RqspMessageKind
    check messageKindFromWire(41'u16, kind) and kind == rqRequestSubLease
    check RqspProtocolMinor >= SubLeaseMinor
