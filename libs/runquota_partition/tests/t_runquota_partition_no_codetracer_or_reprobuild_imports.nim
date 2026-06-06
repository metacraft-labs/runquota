## Static check: the runquota_partition source tree must not contain
## any import of a `repro_*` or `ct_*` symbol. This protects the
## library's "no codetracer, no reprobuild" boundary.
##
## The check runs at compile time via `staticExec` so a forbidden
## import lands as a compile error inside this test, not a runtime
## failure. The check also inspects the library nimble file to catch
## `requires` entries pointing at forbidden packages.

import std/[os, strutils, unittest]

const partitionRoot = currentSourcePath().parentDir.parentDir
  ## .../libs/runquota_partition

const srcDir = partitionRoot / "src"
const nimbleFile = partitionRoot / "runquota_partition.nimble"

const ImportGrep = staticExec(
  "grep -rE '^[[:space:]]*import[[:space:]]+(repro_|ct_)' " &
  "--include='*.nim' " & srcDir & " || true"
).strip

const FromImportGrep = staticExec(
  "grep -rE '^[[:space:]]*from[[:space:]]+(repro_|ct_)' " &
  "--include='*.nim' " & srcDir & " || true"
).strip

const IncludeGrep = staticExec(
  "grep -rE '^[[:space:]]*include[[:space:]]+(repro_|ct_)' " &
  "--include='*.nim' " & srcDir & " || true"
).strip

const RequiresGrep = staticExec(
  "grep -E 'requires[[:space:]]+.(repro_|ct_)' " & nimbleFile & " || true"
).strip

const NimbleFileContents = staticRead(nimbleFile)

suite "runquota_partition has no codetracer or reprobuild imports":

  test "no `import repro_* | ct_*` in any source file":
    check ImportGrep.len == 0

  test "no `from repro_* | ct_*` in any source file":
    check FromImportGrep.len == 0

  test "no `include repro_* | ct_*` in any source file":
    check IncludeGrep.len == 0

  test "nimble file does not require any repro_* or ct_* package":
    check RequiresGrep.len == 0

  test "nimble file only requires runquota_core (plus nim)":
    var requiresLines: seq[string] = @[]
    for line in NimbleFileContents.splitLines:
      let stripped = line.strip
      if stripped.startsWith("requires "):
        requiresLines.add(stripped)
    check requiresLines.len >= 1
    for line in requiresLines:
      # Acceptable: nim or runquota_core. Reject anything else with the
      # forbidden prefixes.
      check not line.contains("\"repro_")
      check not line.contains("\"ct_")
