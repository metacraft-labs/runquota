## The wire form of session groups, and what an older peer sees.
##
## A session group travels as an OPTIONAL TRAILING BLOCK of `RegisterSession`,
## so two compatibility facts have to hold, and both are about bytes:
##
## * a `RegisterSession` from a client that predates groups decodes, as a
##   session with no group (the daemon then places it in the interactive
##   group);
## * a `RegisterSession` with no group encodes to exactly those bytes, so the
##   current client can still talk to a daemon that predates groups.
##
## The old payload is written field by field here, not through the current
## encoder, so the first fact cannot pass by the encoder agreeing with itself.
##
## NO MOCKS: the real codec over real byte strings, and the client library's
## environment reader over the real process environment.

import std/[os, unittest]

import runquota_client
import runquota_codec
import runquota_core
import runquota_protocol

proc oldRegisterSession(name, version: string): string =
  var w = writer()
  w.writeString(name)
  w.writeString(version)
  w.writeMetadata(metadataNone())
  w.data

suite "session group codec":
  test "an old client's RegisterSession decodes as no group":
    var msg: RegisterSessionMessage
    check decodeRegisterSession(oldRegisterSession("old", "1"), msg)
    check msg.name == "old"
    check msg.group.name.len == 0

  test "no group encodes to the old bytes":
    check encodeRegisterSession(RegisterSessionMessage(name: "old",
      version: "1", metadata: metadataNone())) == oldRegisterSession("old", "1")

  test "a group and its attributes round trip":
    let sent = RegisterSessionMessage(name: "s", version: "1",
      metadata: metadataNone(), group: SessionGroupDeclaration(
        name: "host:3", priorityPresent: true, priority: sessionPriorityUrgent,
        cacheDeadlinePresent: true, cacheDeadlineUnixMillis: 1_700_000_000_000'u64))
    var got: RegisterSessionMessage
    check decodeRegisterSession(encodeRegisterSession(sent), got)
    check got.group == sent.group
    # Trailing bytes after the block are a malformed frame.
    check not decodeRegisterSession(encodeRegisterSession(sent) & "x", got)

  test "a priority this build does not know is refused, not misread":
    var bytes = encodeUpdateSessionGroup(UpdateSessionGroupMessage(
      group: "g", priorityPresent: true, priority: sessionPriorityLow))
    var update: UpdateSessionGroupMessage
    check decodeUpdateSessionGroup(bytes, update)
    # The priority is the u32 after the group string (4-byte length + 1
    # byte) and the presence flag.
    let offset = bytes.len - 4 - 8 - 4
    bytes[offset] = char(ord(high(SessionPriority)) + 1)
    check not decodeUpdateSessionGroup(bytes, update)

  test "UpdateSessionGroup and its answer round trip":
    let update = UpdateSessionGroupMessage(group: "host:3",
      priorityPresent: false, priority: sessionPriorityNormal,
      cacheDeadlineChange: cacheDeadlineClear)
    var gotUpdate: UpdateSessionGroupMessage
    check decodeUpdateSessionGroup(encodeUpdateSessionGroup(update), gotUpdate)
    check gotUpdate == update
    let answer = SessionGroupUpdatedMessage(group: "host:3", ownerUid: 1000,
      priority: sessionPriorityHigh, cacheDeadlinePresent: true,
      cacheDeadlineUnixMillis: 42, sessions: 2)
    var gotAnswer: SessionGroupUpdatedMessage
    check decodeSessionGroupUpdated(encodeSessionGroupUpdated(answer), gotAnswer)
    check gotAnswer == answer

  test "the daemon announces session groups by its protocol minor":
    check SessionGroupsMinor > RetirementMinor
    check RqspProtocolMinor >= SessionGroupsMinor
    var kind: RqspMessageKind
    check messageKindFromWire(39'u16, kind) and kind == rqUpdateSessionGroup
    check messageKindFromWire(40'u16, kind) and kind == rqSessionGroupUpdated
    var old = RunQuotaClient()
    old.capabilities.protocolMinor = SessionGroupsMinor - 1
    check not old.supportsSessionGroups()

  test "the client reads the launcher's environment":
    for key in [SessionGroupEnvVar, SessionPriorityEnvVar,
        SessionCacheTtlEnvVar]:
      delEnv(key)
    check sessionGroupFromEnvironment().name.len == 0
    putEnv(SessionGroupEnvVar, "host:7")
    putEnv(SessionPriorityEnvVar, "urgent")
    putEnv(SessionCacheTtlEnvVar, "300")
    var declared = sessionGroupFromEnvironment()
    check declared.name == "host:7"
    check declared.priorityPresent and declared.priority == sessionPriorityUrgent
    check declared.cacheDeadlinePresent
    # Attributes that do not parse are ignored rather than failing the client.
    putEnv(SessionPriorityEnvVar, "HIGH")
    putEnv(SessionCacheTtlEnvVar, "soon")
    declared = sessionGroupFromEnvironment()
    check not declared.priorityPresent
    check not declared.cacheDeadlinePresent
    for key in [SessionGroupEnvVar, SessionPriorityEnvVar,
        SessionCacheTtlEnvVar]:
      delEnv(key)

  test "a group name that cannot be one is refused":
    check sessionGroupNameProblem("host:3").len == 0
    check sessionGroupNameProblem("").len > 0
    check sessionGroupNameProblem("a\nb").len > 0
    check sessionGroupNameProblem(newString(MaxSessionGroupBytes + 1)).len > 0
