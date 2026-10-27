## The client never sends `RetireDaemon` to a daemon that predates it, and
## the image identity both sides compare is the file's content.
##
## WHY. A daemon that does not know a message kind fails to decode the frame
## header and closes the connection, taking every session on it along -- so
## a client that sent `RetireDaemon` to a minor-1 daemon over a connection
## carrying a build's session would end that build. The client therefore
## reads the minor from `HelloOk` first and raises instead
## (reprobuild-specs/RunQuota-Host-Configuration.md, "A daemon from another
## build makes way"). And the identity compared is `imageDigestOf`: a
## version string cannot tell two builds apart.
##
## NO MOCKS. The client value is the one `connect` builds, with the minor an
## old daemon reports; the refusal happens before anything would touch its
## connection, which is what is asserted. Digests are taken of real files.

import std/[os, strutils, unittest]

import runquota_client
import runquota_core
import runquota_core/image_digest
import runquota_core/sha256
import runquota_protocol

proc clientOfMinor(minor: uint16): RunQuotaClient =
  result = RunQuotaClient(state: csClosed, daemonVersion: "0.1.3",
    capabilities: defaultCapabilities("windows", "named-pipe", milliCpu(1000),
      bytes(1)),
    flow: defaultFlowControlLimits())
  result.capabilities.protocolMinor = minor

suite "RetireDaemon on the client":

  test "a daemon below RetirementMinor is not sent the request":
    var old = clientOfMinor(RetirementMinor - 1)
    check not old.supportsRetirement()
    expect RunQuotaClientError:
      discard old.retireDaemon(expectedImageDigest = "sha256:00")
    check old.lastDiagnostic.code == diagUnsupportedVersion
    check "(0.1.3, protocol minor " & $(RetirementMinor - 1) &
      ") predates RetireDaemon" in old.lastDiagnostic.message
    # NOTHING WAS FRAMED: no request id was spent and none is in flight.
    check old.nextRequestId == 0'u64
    check old.inflightRequestIds.len == 0

  test "a daemon at RetirementMinor is one the client will ask":
    check clientOfMinor(RetirementMinor).supportsRetirement()

suite "image identity":

  test "the digest is the content's, named by algorithm":
    let root = getTempDir() / ("rq-imgdigest-" & $getCurrentProcessId())
    removeDir(root)
    createDir(root)
    defer: removeDir(root)
    let image = root / "runquotad"
    writeFile(image, "MZ one build")
    check imageDigestOf(image) == ImageDigestPrefix & sha256Hex("MZ one build")
    # A copy is the same build; one more byte is another.
    let copy = root / "copy"
    copyFile(image, copy)
    check imageDigestOf(copy) == imageDigestOf(image)
    writeFile(copy, "MZ one build!")
    check imageDigestOf(copy) != imageDigestOf(image)

  test "a file that cannot be read proves nothing":
    check imageDigestOf("") == ""
    check imageDigestOf(getTempDir() / "rq-no-such-runquotad-image") == ""
