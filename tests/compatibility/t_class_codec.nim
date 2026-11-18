## The wire form of a session group's class, and what an older peer sees.
##
## The class travels as an OPTIONAL TRAILING BLOCK of `RegisterSession`,
## after the group and sizing blocks, announced by protocol minor 12
## (`ClassesMinor`). The compatibility facts, all about bytes:
##
## * a `RegisterSession` without a class -- from any older client, or from
##   this one when no class is named -- is byte-identical to what a minor-11
##   client sends, so this client still talks to an older daemon and an
##   older client's registration decodes here with no class;
## * a class block decodes after empty group and sizing blocks, and a
##   class that breaks the class-name rule, an empty class block, or bytes
##   after it are a malformed frame;
## * the client library reads `RUNQUOTA_CLASS` with or without a group, and
##   sends the class only to a daemon at minor 12 or above.
##
## The old payloads are written field by field here, not through the
## current encoder, so they cannot pass by the encoder agreeing with itself.
##
## NO MOCKS: the real codec over real byte strings, and the client library's
## environment reader over the real process environment.

import std/[os, strutils, unittest]

import runquota_client
import runquota_codec
import runquota_core
import runquota_protocol

proc minor11RegisterSession(name, version, group, project,
                            entryPoint: string): string =
  ## A minor-11 client's `RegisterSession`: the group block when it names a
  ## group or a project, then the sizing block when it declares one.
  var w = writer()
  w.writeString(name)
  w.writeString(version)
  w.writeMetadata(metadataNone())
  let sizing = project.len > 0 or entryPoint.len > 0
  if group.len > 0 or sizing:
    w.writeString(group)
    w.writeBool(false)
    w.writeU32(uint32(ord(sessionPriorityNormal)))
    w.writeBool(false)
    w.writeU64(0'u64)
  if sizing:
    w.writeString(project)
    w.writeString(entryPoint)
  w.data

proc classPayload(group, project, entryPoint, class: string): string =
  ## A minor-12 `RegisterSession` naming `class`, written field by field.
  var w = writer()
  w.writeString("s")
  w.writeString("1")
  w.writeMetadata(metadataNone())
  w.writeString(group)
  w.writeBool(false)
  w.writeU32(uint32(ord(sessionPriorityNormal)))
  w.writeBool(false)
  w.writeU64(0'u64)
  w.writeString(project)
  w.writeString(entryPoint)
  w.writeString(class)
  w.data

suite "class codec":
  test "minor 12 announces classes":
    check ClassesMinor == 12'u16
    check RqspProtocolMinor >= ClassesMinor

  test "without a class the bytes are minor 11's":
    for (group, project, entry) in [("", "", ""), ("g", "", ""),
        ("", "p", "build"), ("g", "p", "")]:
      let msg = RegisterSessionMessage(name: "s", version: "1",
        metadata: metadataNone(), group: SessionGroupDeclaration(name: group,
          priority: sessionPriorityNormal),
        project: project, entryPoint: entry)
      check encodeRegisterSession(msg) ==
        minor11RegisterSession("s", "1", group, project, entry)
      var got: RegisterSessionMessage
      check decodeRegisterSession(
        minor11RegisterSession("s", "1", group, project, entry), got)
      check got.group.className == ""
      check got.group.name == group

  test "a class round trips, with and without a group or sizing":
    for (group, project, entry) in [("", "", ""), ("job-7", "", ""),
        ("", "proj", "test"), ("job-7", "proj", "")]:
      let sent = RegisterSessionMessage(name: "s", version: "1",
        metadata: metadataNone(), group: SessionGroupDeclaration(name: group,
          priority: sessionPriorityNormal, className: "ci"),
        project: project, entryPoint: entry)
      let bytes = encodeRegisterSession(sent)
      check bytes == classPayload(group, project, entry, "ci")
      var got: RegisterSessionMessage
      check decodeRegisterSession(bytes, got)
      check got.group.className == "ci"
      check got.group.name == group
      check got.project == project
      check got.entryPoint == entry
      check not decodeRegisterSession(bytes & "x", got)

  test "a class outside the rule, or an empty class block, is refused":
    var got: RegisterSessionMessage
    for bad in ["", "c i", "c.i", "a\x01", repeat('a', 65), "\xc3\xa9"]:
      check not decodeRegisterSession(classPayload("g", "", "", bad), got)
    check decodeRegisterSession(classPayload("g", "", "", repeat('a', 64)),
      got)
    # An empty sizing block with nothing after it is still not something
    # any encoder writes.
    # (An empty group block is 18 bytes, an empty sizing block 8.)
    check not decodeRegisterSession(minor11RegisterSession("s", "1", "", "",
      "") & repeat('\x00', 18 + 8), got)

  test "the client library reads RUNQUOTA_CLASS with or without a group":
    let saved = (getEnv(SessionGroupEnvVar), getEnv(ClassEnvVar))
    defer:
      putEnv(SessionGroupEnvVar, saved[0])
      putEnv(ClassEnvVar, saved[1])
    putEnv(SessionGroupEnvVar, "")
    putEnv(ClassEnvVar, "ci")
    check sessionGroupFromEnvironment().className == "ci"
    check sessionGroupFromEnvironment().name == ""
    putEnv(SessionGroupEnvVar, "job-1")
    check sessionGroupFromEnvironment().className == "ci"
    check sessionGroupFromEnvironment().name == "job-1"
    putEnv(ClassEnvVar, "")
    check sessionGroupFromEnvironment().className == ""

  test "the class-name rule":
    check classNameProblem("ci") == ""
    check classNameProblem("vm-pool_2") == ""
    check classNameProblem("").len > 0
    check classNameProblem("c.i").len > 0
    check classNameProblem(repeat('a', 65)).len > 0
