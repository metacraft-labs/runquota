## THE PACKAGE'S CLAIMS ABOUT THE PRODUCT, CHECKED AGAINST THE PRODUCT.
##
## `packaging/runquota_dist.nim` is compiled by `repro build` under a Nim
## invocation that has none of `libs/` on its path — it imports only
## reprobuild's packaging layer. That isolation is what makes it usable
## from this repository at all, and it is also what lets it drift: every
## fact it states about RunQuota is a STRING, and a string that stopped
## being true would still produce a perfectly valid package.
##
## Three of those strings are load-bearing, and each has a failure mode
## that only a machine ever sees:
##
##   * THE SERVICE NAME. `runquota_dist.nim`'s `RunQuotaDaemonServiceName`
##     becomes the MSI's `ServiceInstall.Name`; `runquotad.nim`'s
##     `windowsServiceName` is what the image hands
##     `StartServiceCtrlDispatcherW`. They are compared by the SCM at
##     `sc start` time and nowhere else, and a mismatch is a service that
##     registers and cannot run.
##
##   * THE STATE DIRECTORIES. The package documents where host state
##     lives; the daemon's `hostWideStateDir` decides. Reprobuild's M1
##     N22 is what the two disagreeing looks like — an MSI that
##     registered a service with `--root=/var/lib/...` on a machine with
##     no such path. RunQuota's answer is that the SERVICE PASSES NO
##     PATH AT ALL, which is only correct while the constants here agree
##     with the daemon's; the moment they do not, the package's own
##     documentation is wrong about where an operator will find the
##     store.
##
##   * `execArgs` BEING EMPTY. That emptiness is the mechanism by which
##     no POSIX path can cross into `BINARY_PATH_NAME`. An argument added
##     here later — for a capacity flag, say — reintroduces exactly the
##     defect the emptiness removes, so it has to be a deliberate act
##     that edits this file too.
##
## READ AS TEXT, NOT IMPORTED. `runquota_dist.nim` imports
## `repro_dsl_stdlib/packaging`, which is not on this suite's path and
## must not be: RunQuota's test suite cannot require a reprobuild
## checkout. So the assertions below are over the source bytes, which is
## the same shape reprobuild's own `t_packaging_service_exec_args` uses
## and for the same reason.
##
## `doAssert` AND NOT `check`, throughout. Stock Nim's `unittest.check`
## inside a HELPER PROC prints its failure and lets the test report
## `[OK]`; this campaign has already been misled by that once.

import std/[os, strutils, unittest]

const testSourceDir = currentSourcePath().parentDir()

proc repoRoot(): string =
  ## `tests/unit/<this file>` -> the repository root. Derived from the
  ## source path rather than from `getCurrentDir()` so this cannot
  ## silently read a DIFFERENT tree.
  result = testSourceDir.parentDir().parentDir()
  doAssert fileExists(result / "runquota.nimble"),
    "repo root " & result & " has no runquota.nimble"

proc readSource(relPath: string): string =
  let path = repoRoot() / relPath
  doAssert fileExists(path), "expected source file is missing: " & path
  result = readFile(path)
  doAssert result.len > 0, "source file is empty: " & path

proc quotedValueAfter(text, needle, what: string): string =
  ## The contents of the first double-quoted string that follows
  ## ``needle``.
  ##
  ## THE ABSENCE OF ``needle`` IS A FAILURE, not an empty answer. A
  ## renamed constant would otherwise make every assertion below compare
  ## "" with "" and pass — which is precisely the vacuous-green shape
  ## these tests exist to refuse.
  let at = text.find(needle)
  doAssert at >= 0, "could not find " & what & " (searched for: " & needle & ")"
  let openQuote = text.find('"', at + needle.len)
  doAssert openQuote >= 0, "no opening quote after " & what
  let closeQuote = text.find('"', openQuote + 1)
  doAssert closeQuote > openQuote, "no closing quote after " & what
  result = text[openQuote + 1 ..< closeQuote]
  doAssert result.len > 0, what & " is an empty string"

suite "packaging contract":
  test "the package and the binary agree on the Windows service name":
    let distText = readSource("packaging/runquota_dist.nim")
    let appText = readSource("apps/runquotad/runquotad.nim")
    let fromDist = quotedValueAfter(distText,
      "RunQuotaDaemonServiceName* =", "the package's service name")
    let fromApp = quotedValueAfter(appText,
      "windowsServiceName* =", "the binary's SCM service name")
    doAssert fromDist == fromApp,
      "the MSI would register '" & fromDist &
      "' while the image answers to '" & fromApp &
      "'; the SCM compares these at start time and nothing else does"
    # An ASCII name is a hard requirement of the dispatcher host
    # (`allocWide` refuses anything else at run time, which is far too
    # late), and an SCM service name may not contain a forward slash or
    # a backslash.
    for ch in fromDist:
      doAssert ord(ch) < 128, "service name must be ASCII: " & fromDist
      doAssert ch != '/' and ch != '\\',
        "an SCM service name may not contain a path separator: " & fromDist

  test "the package's state directories are the daemon's own":
    let distText = readSource("packaging/runquota_dist.nim")
    let identityText = readSource(
      "libs/runquota_observation_store/src/runquota_observation_store/identity.nim")
    # `hostWideStateDir`'s three arms, in the order the `when` writes
    # them. Each is located by the guard that precedes it, so a
    # reordering of the `when` cannot make this read the wrong arm.
    let windowsArm = quotedValueAfter(
      identityText[identityText.find("hostWideStateDir* =") .. ^1],
      "when defined(windows):", "the daemon's Windows state directory")
    let darwinArm = quotedValueAfter(
      identityText[identityText.find("hostWideStateDir* =") .. ^1],
      "elif defined(macosx):", "the daemon's macOS state directory")
    let linuxArm = quotedValueAfter(
      identityText[identityText.find("hostWideStateDir* =") .. ^1],
      "else:", "the daemon's Linux state directory")

    doAssert quotedValueAfter(distText, "WindowsStateDir* =",
      "the package's Windows state directory") == windowsArm,
      "the package and the daemon disagree about C:\\ProgramData\\runquota"
    doAssert quotedValueAfter(distText, "DarwinStateDir* =",
      "the package's macOS state directory") == darwinArm,
      "the package and the daemon disagree about the macOS state directory"
    doAssert quotedValueAfter(distText, "PosixStateDir* =",
      "the package's Linux state directory") == linuxArm,
      "the package and the daemon disagree about the Linux state directory"
    # The arms must not be the same string as each other, or the check
    # above would pass for a `hostWideStateDir` that had collapsed to
    # one per-target answer — which is the defect, not the contract.
    doAssert windowsArm != linuxArm and windowsArm != darwinArm,
      "the daemon's state directory is not actually per-target"

  test "the service carries no arguments":
    let distText = readSource("packaging/runquota_dist.nim")
    let at = distText.find("execArgs:")
    doAssert at >= 0, "the ServiceDef no longer sets execArgs at all"
    let line = distText[at ..< distText.find('\n', at)]
    doAssert line.replace(" ", "") == "execArgs:@[],",
      "ServiceDef.execArgs must stay empty — every renderer passes it " &
      "through verbatim, so one list has to be right for systemd, " &
      "launchd and the SCM at once. Found: " & line.strip()

  test "the service is system-scoped":
    let distText = readSource("packaging/runquota_dist.nim")
    doAssert distText.contains("scope: ssSystem"),
      "runquotad must be ssSystem: it is ONE PER HOST by construction, " &
      "and an ssUser service is dropped entirely by msiServiceRows, " &
      "which would yield a Windows package with no service at all"
    doAssert not distText.contains("scope: ssUser"),
      "no RunQuota service may be ssUser"

  test "the three version sources agree":
    # `runquota.nimble` is what nimble reads, `runquota_core`'s
    # `RunQuotaVersion` is what `--version` prints, and
    # `RunQuotaPackageVersion` is what every package format carries.
    # `scripts/bump_version.sh` rewrites all three in one act; this is
    # what makes a bump that missed one a failure rather than a release
    # whose binaries report the previous version.
    let fromNimble = quotedValueAfter(readSource("runquota.nimble"),
      "version =", "the nimble version")
    let fromCore = quotedValueAfter(
      readSource("libs/runquota_core/src/runquota_core.nim"),
      "RunQuotaVersion* =", "the compiled-in version")
    let fromPackaging = quotedValueAfter(
      readSource("packaging/runquota_dist.nim"),
      "RunQuotaPackageVersion* =", "the packaged version")
    doAssert fromNimble == fromCore,
      "runquota.nimble says " & fromNimble & " and runquota_core says " & fromCore
    doAssert fromNimble == fromPackaging,
      "runquota.nimble says " & fromNimble & " and the packaging recipe says " &
      fromPackaging

  test "the upgrade code is a well-formed GUID":
    # A malformed one is rejected by `light` at build time; a CHANGED one
    # is accepted by everything and silently turns the next release into
    # a side-by-side install rather than an upgrade. Only the shape can
    # be checked here; the runbook carries the "never change it" rule.
    let code = quotedValueAfter(readSource("packaging/runquota_dist.nim"),
      "RunQuotaUpgradeCode* =", "the MSI upgrade code")
    doAssert code.len == 38, "an MSI UpgradeCode is {8-4-4-4-12}: " & code
    doAssert code[0] == '{' and code[^1] == '}', "not brace-wrapped: " & code
    for i, ch in code[1 ..< code.high]:
      if i in [8, 13, 18, 23]:
        doAssert ch == '-', "expected a dash at offset " & $i & " of " & code
      else:
        doAssert ch in {'0' .. '9', 'A' .. 'F'},
          "an UpgradeCode is upper-case hex: " & code
