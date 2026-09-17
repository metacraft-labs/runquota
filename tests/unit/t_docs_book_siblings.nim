## The documentation book's sibling-path resolution, and the skip it produces.
##
## `docs/book-isonim` is an `isonim-docs` static-site-generator site whose Nim
## compiles need nine sibling source trees on the path. `repro.nim`'s
## `docsBookIsonim` block declares the generated `nim.cfg` as a build-graph
## input, and it must SKIP the whole book -- cleanly, emitting nothing -- when
## those siblings are not checked out, because most of them are not part of the
## RunQuota project manifest and a normal RunQuota workspace does not have
## them. Every other target in `repro.nim` has to resolve regardless.
##
## WHAT IS ACTUALLY EXERCISED HERE, and why it is the skip. The book cannot be
## RENDERED in a workspace without those siblings, so an end-to-end "the book
## builds" test is not available from this repository alone. The decision that
## precedes it is, and it is the one with a failure mode worth a test: an
## all-or-nothing path set. A half-resolved set does not fail honestly -- it
## produces `cannot open file: <some framework module>` from deep inside the
## SSG, naming a module instead of the missing checkout. So the clauses below
## are written as REFUSALS with negative controls: a set missing one repo, and
## a set whose repo is present but whose subdirectory is not, must both yield
## zero paths and name what was missing, and `bookNimCfgText` must refuse to
## render anything for them.
##
## NO MOCKS, AND NONE ARE JUSTIFIABLE HERE. Every clause runs against real
## directories created under a real temporary directory, because the entire
## subject is `dirExists` against a real workspace layout; a stub filesystem
## would be exactly as happy with the existence checks removed, which is the
## defect this file exists to catch. The one pure-function clause
## (`toNimCfgPath` on a Windows path) needs no filesystem at all and touches
## none.
##
## THE WINDOWS CLAUSE CANNOT USE A REAL PATH on this host: POSIX permits `\` in
## a file name, so a directory literally named `M:\m\...` would be one
## component and would prove nothing about the Windows layout. It is asserted
## against the pure formatter instead, which is the function the Windows build
## actually depends on, and the clause is labelled as such rather than passed
## off as an end-to-end Windows check.

import std/[os, strutils, unittest]

# The module under test, reached exactly the way `repro.nim` reaches it: a
# relative path, no `--path:` entry, no dependency on `config.nims`.
import "../../docs/book-isonim/sibling_paths"

const
  RepoRoot = currentSourcePath().parentDir().parentDir().parentDir()
  BookDir = RepoRoot / "docs" / "book-isonim"

  ExpectedSpec = [
    ("isonim-docs", "src"),
    ("codetracer-design-system", "nim"),
    ("isonim", "src"),
    ("nim-everywhere", "src"),
    ("nim-faststreams", ""),
    ("nim-stew", ""),
    ("isonim", "vendor/chronicles"),
    ("isonim", "vendor/serialization"),
    ("isonim", "vendor/json_serialization"),
  ]
    ## The nine entries `sibling-paths.txt` is expected to declare, IN ORDER.
    ## Duplicated here on purpose: this is the clause that notices an entry
    ## being added, removed or reordered, so it has to be an independent
    ## statement of the list rather than a re-read of the file.

proc makeWorkspace(name: string; siblings: openArray[BookSibling];
                   skip = ""): string =
  ## A real temporary workspace containing a `runquota` checkout directory and
  ## a directory for every sibling path in `siblings`, except any whose repo
  ## name equals `skip`. Returns the *checkout* path, which is what
  ## `resolveBookSiblings` takes.
  let ws = getTempDir() / ("runquota_book_siblings_" & name)
  removeDir(ws)
  createDir(ws)
  for sibling in siblings:
    if sibling.repo == skip:
      continue
    let full =
      if sibling.subPath.len > 0: ws / sibling.repo / sibling.subPath
      else: ws / sibling.repo
    createDir(full)
  result = ws / "runquota"
  createDir(result)

suite "docs/book-isonim sibling paths":
  test "sibling-paths.txt declares the nine trees the book needs, in order":
    let siblings = readBookSiblingSpec(BookDir)
    check siblings.len == ExpectedSpec.len
    for i, expected in ExpectedSpec:
      check siblings[i].repo == expected[0]
      check siblings[i].subPath == expected[1]

  test "comments and blank lines are not entries":
    let parsed = parseBookSiblingSpec("""
# a comment

  isonim-docs src

# another
nim-stew .
""")
    check parsed.len == 2
    check parsed[0].repo == "isonim-docs"
    check parsed[0].subPath == "src"
    check parsed[1].repo == "nim-stew"
    check parsed[1].subPath == ""

  test "a malformed entry is raised, never silently dropped":
    # Dropping it would reintroduce the half-a-path-set failure from the
    # other direction: a set that looks complete and is one short.
    expect ValueError:
      discard parseBookSiblingSpec("isonim-docs src extra\n")
    expect ValueError:
      discard parseBookSiblingSpec("isonim-docs\n")

  test "a complete workspace resolves to nine --path lines in declared order":
    let siblings = readBookSiblingSpec(BookDir)
    let checkout = makeWorkspace("complete", siblings)
    defer: removeDir(checkout.parentDir)

    let resolved = resolveBookSiblings(checkout, siblings)
    check resolved.ok
    check resolved.missingRepo == ""
    check resolved.paths.len == siblings.len
    check resolved.cfgLines.len == siblings.len
    for i, sibling in siblings:
      let tail =
        if sibling.subPath.len > 0: sibling.repo & "/" & sibling.subPath
        else: sibling.repo
      check resolved.paths[i].endsWith(tail)
      check resolved.paths[i].isAbsolute
      check resolved.cfgLines[i] == "--path:\"" & resolved.paths[i] & "\""
    check bookNimCfgText(resolved) == resolved.cfgLines.join("\n") & "\n"

  test "a worktree one level deeper still finds the workspace root":
    # `git worktree list` in this repository shows the `<ws>/wt-<name>/runquota`
    # shape, so the search has to reach two parents up, not one.
    let siblings = readBookSiblingSpec(BookDir)
    let checkout = makeWorkspace("nested", siblings)
    defer: removeDir(checkout.parentDir)
    let nested = checkout.parentDir / "wt-book" / "runquota"
    createDir(nested)

    let resolved = resolveBookSiblings(nested, siblings)
    check resolved.ok
    check resolved.workspaceRoot == normalizedPath(absolutePath(checkout.parentDir))

  test "ONE missing repo skips the whole set and names it":
    let siblings = readBookSiblingSpec(BookDir)
    let checkout = makeWorkspace("missing", siblings, skip = "nim-stew")
    defer: removeDir(checkout.parentDir)

    let resolved = resolveBookSiblings(checkout, siblings)
    check not resolved.ok
    check resolved.missingRepo == "nim-stew"
    # The negative control that matters: NO partial path set escapes.
    check resolved.paths.len == 0
    check resolved.cfgLines.len == 0
    check bookNimCfgText(resolved) == ""

  test "a present repo missing its subdirectory is refused the same way":
    let siblings = readBookSiblingSpec(BookDir)
    let checkout = makeWorkspace("subdir", siblings)
    defer: removeDir(checkout.parentDir)
    removeDir(checkout.parentDir / "isonim" / "vendor" / "serialization")

    let resolved = resolveBookSiblings(checkout, siblings)
    check not resolved.ok
    check resolved.missingRepo == "isonim/vendor/serialization"
    check resolved.cfgLines.len == 0

  test "an empty workspace skips without raising":
    let siblings = readBookSiblingSpec(BookDir)
    let ws = getTempDir() / "runquota_book_siblings_empty"
    removeDir(ws)
    createDir(ws / "runquota")
    defer: removeDir(ws)

    let resolved = resolveBookSiblings(ws / "runquota", siblings)
    check not resolved.ok
    check resolved.missingRepo.len > 0
    check resolved.cfgLines.len == 0

  test "a nim.cfg path never carries a backslash":
    # Nim's cfg reader lexes the `"..."` as a STRING LITERAL, so on Windows
    # `--path:"M:\m\repro-fixes\isonim-docs\src"` dies at `\m` with
    # `invalid character constant` and takes the whole book build with it.
    # A pure-function clause: see the header for why it cannot use a real path.
    let windowsPath = "M:\\m\\repro-fixes\\isonim-docs\\src"
    check toNimCfgPath(windowsPath) == "M:/m/repro-fixes/isonim-docs/src"
    check '\\' notin bookNimCfgLine(windowsPath)
    check bookNimCfgLine(windowsPath) ==
      "--path:\"M:/m/repro-fixes/isonim-docs/src\""
    # And a POSIX path is passed through untouched.
    check toNimCfgPath("/home/x/isonim-docs/src") == "/home/x/isonim-docs/src"

  test "THIS checkout either resolves completely or skips cleanly":
    # The live clause. In a workspace without the framework siblings -- which
    # is the normal RunQuota workspace -- this is the skip the `repro.nim`
    # block takes. In one that has them all it is the build. Both are correct;
    # what must never happen is a partial set, and that is what is asserted.
    let siblings = readBookSiblingSpec(BookDir)
    let resolved = resolveBookSiblings(RepoRoot, siblings)
    if resolved.ok:
      check resolved.cfgLines.len == siblings.len
      check resolved.missingRepo == ""
    else:
      check resolved.cfgLines.len == 0
      check resolved.paths.len == 0
      check resolved.missingRepo.len > 0
      check bookNimCfgText(resolved) == ""

  test "repro.nim reads the list rather than keeping a copy of it":
    # The invariant the single list exists for. CodeTracer's equivalent list
    # lived in its `repro.nim` AND in its deploy script; one gained
    # `codetracer-design-system/nim` and the other did not, and the graph
    # action failed with `cannot open file: metacraft_docs_theme` while the
    # deploy lane built the book. A second copy here would be the same bug.
    let reproNim = readFile(RepoRoot / "repro.nim")
    check "readBookSiblingSpec" in reproNim
    # Comment lines are excluded: the block's prose names two of these repos
    # while explaining why the list is data, and the invariant is about CODE.
    # A re-inlined list would spell each repo as a Nim string literal, so that
    # -- quotes included -- is what is searched for.
    var code = ""
    for rawLine in reproNim.splitLines():
      if rawLine.strip().startsWith("#"):
        continue
      code.add rawLine
      code.add '\n'
    for expected in ExpectedSpec:
      check ("\"" & expected[0] & "\"") notin code
