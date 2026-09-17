## Resolving the sibling source trees the RunQuota book compiles against.
##
## The book (`docs/book-isonim`) is a consumer of the `isonim-docs` static-site
## framework, and framework, theme and transitive Nim packages all live in
## SIBLING REPOSITORIES of this one rather than inside it. Nim reaches them
## through `--path:` entries in a generated `docs/book-isonim/nim.cfg`, and this
## module is what computes those entries.
##
## WHY A MODULE RATHER THAN A FEW LINES INLINE IN `repro.nim`. Two callers need
## the identical answer -- the `docsBookIsonim` block in the repo's `repro.nim`,
## which declares the generated `nim.cfg` as a tracked graph input, and the
## book's own `just nim-cfg` recipe, which writes the same file for a developer
## who is not driving the build through the engine. CodeTracer, whose book this
## one is modelled on, has the same two callers and keeps two hand-maintained
## copies of the list; they drifted, and the symptom was a deploy that built the
## book while the graph action failed with `cannot open file:
## metacraft_docs_theme`. Here the list is data (`sibling-paths.txt`), this
## module is the only parser, and a test can drive both arms of the decision.
##
## DEPENDENCIES: `std` only. `repro.nim` is compiled by the reprobuild engine
## with the project DSL on its path and nothing of RunQuota's own `libs/` tree,
## and it reaches this module by a RELATIVE import, so anything this module
## imported would have to be resolvable in that compile too.

import std/[os, strutils]

type
  BookSibling* = object
    ## One required sibling source tree: a repository name next to this
    ## repository's checkout, and a subdirectory within it (empty for the
    ## repository root).
    repo*: string
    subPath*: string

  BookSiblingResolution* = object
    ## The outcome of resolving the whole set against a candidate workspace.
    ##
    ## `ok` is true only when EVERY sibling resolved; `paths`/`cfgLines` are
    ## empty otherwise. There is deliberately no partial result: a caller that
    ## could reach for half a path set would produce the confusing
    ## `cannot open file` failure this type exists to turn into an honest skip.
    ok*: bool
    workspaceRoot*: string   ## The directory the set resolved against ("" if none).
    missingRepo*: string     ## The first sibling that did not resolve, when `ok` is false.
    paths*: seq[string]      ## Absolute directories, in declared order.
    cfgLines*: seq[string]   ## The `--path:"..."` lines, in the same order.

const
  BookSiblingSpecFile* = "sibling-paths.txt"
    ## The list's file name, inside the book directory.

  RunQuotaWorkspaceSearchDepth* = 2
    ## How far above the repository checkout to look for the workspace root.
    ##
    ## A `repo`-tool workspace puts the checkout directly under the workspace
    ## root (`<ws>/runquota`), but a git worktree of this repository is
    ## conventionally created one level deeper (`<ws>/wt-<name>/runquota` --
    ## `git worktree list` in this repo shows exactly that shape). Both are
    ## reachable within two parents, and `config.nims` already carries the same
    ## one-or-two-levels-up assumption for `nim-shm-lease`.

proc parseBookSiblingSpec*(text: string): seq[BookSibling] =
  ## Parse the `sibling-paths.txt` format: one `<repo> <subpath>` entry per
  ## line, `#` comments and blank lines ignored, `.` meaning the repo root.
  ## Order is preserved because it is the order the `--path:` lines are
  ## emitted in.
  ##
  ## A malformed line is a programming error in a file that lives beside this
  ## module and is covered by a test, so it is raised rather than skipped:
  ## silently dropping an entry would reintroduce the half-a-path-set failure
  ## from the other direction.
  for rawLine in text.splitLines():
    let line = rawLine.strip()
    if line.len == 0 or line.startsWith("#"):
      continue
    let fields = line.splitWhitespace()
    if fields.len != 2:
      raise newException(ValueError,
        BookSiblingSpecFile & ": expected `<repo> <subpath>`, got: " & line)
    result.add BookSibling(
      repo: fields[0],
      subPath: (if fields[1] == ".": "" else: fields[1]))

proc readBookSiblingSpec*(bookDir: string): seq[BookSibling] =
  ## `parseBookSiblingSpec` over `<bookDir>/sibling-paths.txt`.
  parseBookSiblingSpec(readFile(bookDir / BookSiblingSpecFile))

proc toNimCfgPath*(path: string): string =
  ## A filesystem path as it must appear inside a `nim.cfg` string literal.
  ##
  ## FORWARD SLASHES, ALWAYS. The value is interpolated into a file whose
  ## parser -- Nim's own cfg reader -- lexes the `"..."` as a STRING LITERAL, so
  ## a backslash introduces an escape. On Windows
  ## `--path:"M:\m\repro-fixes\isonim-docs\src"` dies at the first pair with
  ## `nim.cfg(1, 12) Error: invalid character constant` (`\m`), or `expected a
  ## hex digit` under `C:\Users` (`\U`), and takes the whole book build with it.
  ## `nim` accepts forward slashes in `--path` on Windows, and a POSIX path
  ## carries no backslashes, so this is a no-op off Windows and load-bearing on
  ## it.
  path.replace('\\', '/')

proc bookNimCfgLine*(path: string): string =
  ## One `--path:"..."` line for the generated `nim.cfg`.
  "--path:\"" & toNimCfgPath(path) & "\""

proc resolveIn*(workspaceRoot: string;
                siblings: openArray[BookSibling]): BookSiblingResolution =
  ## Resolve the whole sibling set against ONE candidate workspace root.
  ##
  ## All-or-nothing: the first sibling whose directory does not exist sets
  ## `missingRepo` and returns an empty, not-ok result.
  result.workspaceRoot = workspaceRoot
  if workspaceRoot.len == 0:
    result.missingRepo = (if siblings.len > 0: siblings[0].repo else: "")
    return
  var paths: seq[string] = @[]
  for sibling in siblings:
    let repoRoot = workspaceRoot / sibling.repo
    if not dirExists(repoRoot):
      result.missingRepo = sibling.repo
      return
    let full =
      if sibling.subPath.len > 0: repoRoot / sibling.subPath
      else: repoRoot
    if not dirExists(full):
      # A present repo missing the subdirectory we need is the same class of
      # problem as an absent repo -- a stale checkout predating the layout --
      # and it must produce the same honest skip rather than a `--path:` to a
      # directory Nim will silently ignore.
      result.missingRepo = sibling.repo & "/" & sibling.subPath
      return
    paths.add normalizedPath(absolutePath(full))
  result.ok = true
  result.paths = paths
  for path in paths:
    result.cfgLines.add bookNimCfgLine(path)

proc countResolvable(workspaceRoot: string;
                     siblings: openArray[BookSibling]): int =
  if workspaceRoot.len == 0:
    return 0
  for sibling in siblings:
    if dirExists(workspaceRoot / sibling.repo):
      inc result

proc workspaceCandidates*(projectRoot: string): seq[string] =
  ## The directories that may be the workspace root, nearest first.
  var dir = projectRoot
  for _ in 0 ..< RunQuotaWorkspaceSearchDepth:
    let parent = dir.parentDir
    if parent.len == 0 or parent == dir:
      break
    result.add normalizedPath(absolutePath(parent))
    dir = parent

proc resolveBookSiblings*(projectRoot: string;
                          siblings: openArray[BookSibling]): BookSiblingResolution =
  ## Resolve the sibling set from a RunQuota checkout at `projectRoot`.
  ##
  ## Tries each candidate workspace root nearest-first and returns the first
  ## COMPLETE resolution. When none is complete the result names the sibling
  ## missing from the candidate that got furthest, so the skip message points
  ## at the workspace a developer is most likely actually in rather than at an
  ## unrelated ancestor directory.
  ##
  ## Never raises and never touches the filesystem beyond `dirExists`, so a
  ## caller evaluating a build graph can treat a not-ok result as "skip the
  ## book" with nothing to clean up.
  var best = BookSiblingResolution(
    missingRepo: (if siblings.len > 0: siblings[0].repo else: ""))
  var bestScore = -1
  for candidate in workspaceCandidates(projectRoot):
    let attempt = resolveIn(candidate, siblings)
    if attempt.ok:
      return attempt
    let score = countResolvable(candidate, siblings)
    if score > bestScore:
      bestScore = score
      best = attempt
  best

proc bookNimCfgText*(resolution: BookSiblingResolution): string =
  ## The full text of the generated `nim.cfg`.
  ##
  ## Only meaningful for an `ok` resolution; a not-ok one yields the empty
  ## string rather than a half-populated config, for the same reason
  ## `resolveIn` refuses to return partial paths.
  if not resolution.ok:
    return ""
  resolution.cfgLines.join("\n") & "\n"
