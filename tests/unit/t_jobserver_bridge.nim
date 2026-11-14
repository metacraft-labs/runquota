## The pure parts of `runquota jobserver` and of the sub-lease wire form:
## token arithmetic, the `MAKEFLAGS` the command receives, the width flags
## removed from make and ninja, joining an inherited bridge, `--mem` sizes,
## `RUNQUOTA_PARENT_LEASE` parsing and the `RequestSubLease` codec.
##
## NO MOCKS: every case is a value in and a value out. The behaviour against
## real tools and a real daemon is in `tests/integration/t_jobserver_command.nim`
## and `tests/integration/t_sub_lease_admission.nim`.
import std/[options, os, posix, strutils, unittest]

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

suite "following a moving width":
  test "a target is whole slots, never more than it allows, never below 1":
    check slotsForTarget(8000) == 8
    check slotsForTarget(2500) == 2
    check slotsForTarget(999) == 1
    check slotsForTarget(0) == 1
    check slotsForTarget(high(uint32)) == int(high(uint32) div 1000'u32)

  test "widening issues tokens at once; narrowing takes only returned ones":
    var fifo = openJobserverFifo(1)
    defer: fifo.closeJobserverFifo()
    check fifo.served == 1
    check fifo.issueTokens(6) == 6
    check fifo.served == 7
    # A client takes five tokens, as five running jobs would.
    let reader = posix.open(fifo.path.cstring, O_RDONLY or O_NONBLOCK)
    check reader >= 0
    var held: array[5, char]
    check posix.read(reader, addr held[0], held.len) == 5
    # Narrowing to 2 slots (1 token) owes 6, but only the 2 tokens back in
    # the FIFO can be taken: the five held are not the bridge's to take.
    check fifo.withholdTokens(6) == 2
    check fifo.served == 5
    # Nothing more is there; a bounded wait returns empty-handed.
    check fifo.withholdTokens(4, waitMillis = 20) == 0
    # Three jobs finish and hand their tokens back: the bridge keeps them.
    let writer = posix.open(fifo.path.cstring, O_WRONLY or O_NONBLOCK)
    check posix.write(writer, addr held[0], 3) == 3
    check fifo.withholdTokens(4, waitMillis = 20) == 3
    check fifo.served == 2
    discard posix.close(reader)
    discard posix.close(writer)

suite "a range asked of an older daemon":
  test "below the negotiated-widths minor, the range becomes one value":
    var resources = resourceVector(milliCpu(16000), bytes(1024'u64))
    let range = WidthRange(present: true, minMilli: 2000,
      preferredMilli: 16000, resizable: true)
    # Minor 5, 8-slot budget: asked for 8 (capped), no block written.
    check not widthForPeer(range, 5, 8000, resources).present
    check resources.cpu.value == 8000'u32
    # Never below the minimum, even when the budget is smaller.
    resources.cpu = milliCpu(16000)
    discard widthForPeer(WidthRange(present: true, minMilli: 4000,
      preferredMilli: 16000), 5, 2000, resources)
    check resources.cpu.value == 4000'u32
    # At minor 6 the range travels unchanged.
    resources.cpu = milliCpu(16000)
    check widthForPeer(range, NegotiatedWidthsMinor, 8000, resources) == range
    check resources.cpu.value == 16000'u32
