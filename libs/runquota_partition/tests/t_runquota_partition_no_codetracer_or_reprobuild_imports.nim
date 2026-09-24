## Static check: the runquota_partition source tree must not contain
## any import of a `repro_*` or `ct_*` symbol. This protects the
## library's "no codetracer, no reprobuild" boundary.
##
## The check also inspects the library nimble file to catch `requires`
## entries pointing at forbidden packages.
##
## The scan is done in Nim rather than by shelling out to `grep`. It used to
## be `staticExec("grep -rE '...' ... || true")`, which only works where the
## compiler's shell is a POSIX one: on Windows `staticExec` runs `cmd.exe`,
## which does not treat single quotes as quoting, so every "match" list held
## cmd's own complaint instead and each check failed on text that had nothing
## to do with the tree. The patterns below are the same ones the `grep`
## expressions spelled, applied line by line.

import std/[os, strutils, unittest]

const partitionRoot = currentSourcePath().parentDir.parentDir
  ## .../libs/runquota_partition

const srcDir = partitionRoot / "src"
const nimbleFile = partitionRoot / "runquota_partition.nimble"

proc startsWithForbiddenPrefix(text: string): bool =
  text.startsWith("repro_") or text.startsWith("ct_")

proc isForbiddenDirective(line, keyword: string): bool =
  ## `^[[:space:]]*<keyword>[[:space:]]+(repro_|ct_)`
  let body = line.strip(leading = true, trailing = false)
  if not body.startsWith(keyword):
    return false
  let rest = body[keyword.len .. ^1]
  if rest.len == 0 or rest[0] notin Whitespace:
    return false
  rest.strip(leading = true, trailing = false).startsWithForbiddenPrefix()

proc isForbiddenRequires(line: string): bool =
  ## `requires[[:space:]]+.(repro_|ct_)`, anywhere on the line.
  var start = 0
  while true:
    let at = line.find("requires", start)
    if at < 0:
      return false
    var i = at + "requires".len
    let spaceStart = i
    while i < line.len and line[i] in Whitespace:
      inc i
    # One or more spaces, then any one character, then the prefix. The
    # character may itself be a space, so try every split of the run.
    for split in spaceStart + 1 .. i:
      if split < line.len and
          line[split + 1 .. ^1].startsWithForbiddenPrefix():
        return true
    start = at + 1

proc forbiddenSourceLines(keyword: string): seq[string] =
  for path in walkDirRec(srcDir):
    if not path.endsWith(".nim"):
      continue
    for line in readFile(path).splitLines():
      if line.isForbiddenDirective(keyword):
        result.add(path & ": " & line)

proc forbiddenRequiresLines(): seq[string] =
  for line in readFile(nimbleFile).splitLines():
    if line.isForbiddenRequires():
      result.add(line)

const NimbleFileContents = staticRead(nimbleFile)

suite "runquota_partition has no codetracer or reprobuild imports":

  test "the scan recognises the shapes it forbids":
    # Without this the checks below could pass because the matcher matches
    # nothing, which is the failure the grep version actually had.
    check "import repro_core".isForbiddenDirective("import")
    check "  import   ct_types".isForbiddenDirective("import")
    check "from repro_x import y".isForbiddenDirective("from")
    check "include ct_x".isForbiddenDirective("include")
    check not "import runquota_core".isForbiddenDirective("import")
    check not "importrepro_x".isForbiddenDirective("import")
    check "requires \"repro_core\"".isForbiddenRequires()
    check "requires  \"ct_x >= 1\"".isForbiddenRequires()
    check not "requires \"runquota_core\"".isForbiddenRequires()
    var sources = 0
    for path in walkDirRec(srcDir):
      if path.endsWith(".nim"):
        inc sources
    check sources > 0

  test "no `import repro_* | ct_*` in any source file":
    check forbiddenSourceLines("import") == newSeq[string]()

  test "no `from repro_* | ct_*` in any source file":
    check forbiddenSourceLines("from") == newSeq[string]()

  test "no `include repro_* | ct_*` in any source file":
    check forbiddenSourceLines("include") == newSeq[string]()

  test "nimble file does not require any repro_* or ct_* package":
    check forbiddenRequiresLines() == newSeq[string]()

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
