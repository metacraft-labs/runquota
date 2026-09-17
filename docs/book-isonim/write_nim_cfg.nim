## Write `docs/book-isonim/nim.cfg` from `sibling-paths.txt`.
##
## The hand-run half of the book's path set, driven by `just nim-cfg`. The
## other half is `repro.nim`'s `docsBookIsonim` block, which writes the same
## file as a tracked build-graph output. Both go through `sibling_paths.nim`
## and neither owns the list, so a developer who writes the file by hand and a
## developer who drives the build through the engine get identical `--path:`
## sets -- which is exactly what CodeTracer's two hand-maintained copies of the
## same list failed to guarantee.
##
## Prints the missing repository and exits non-zero when the siblings are not
## all present, rather than writing a partial config: a half-populated
## `nim.cfg` turns into `cannot open file: <framework module>` from inside the
## static-site generator, which names a module instead of the checkout that is
## actually absent.
##
## `std` only -- this runs in a checkout where the framework is, by definition,
## possibly not there yet.

import std/[os, strutils]

import ./sibling_paths

when isMainModule:
  let bookDir = currentSourcePath().parentDir()
  let repoRoot = bookDir.parentDir.parentDir
  let siblings = readBookSiblingSpec(bookDir)
  let resolved = resolveBookSiblings(repoRoot, siblings)
  if not resolved.ok:
    stderr.writeLine "runquota book: not writing nim.cfg -- sibling source " &
      "tree not found: " & resolved.missingRepo
    stderr.writeLine "  searched workspace roots: " &
      workspaceCandidates(repoRoot).join(", ")
    stderr.writeLine "  the book needs these next to the runquota checkout: " &
      bookDir / BookSiblingSpecFile
    quit 1
  let target = bookDir / "nim.cfg"
  writeFile(target, bookNimCfgText(resolved))
  echo "wrote ", target, " (", resolved.cfgLines.len,
    " --path entries, workspace root ", resolved.workspaceRoot, ")"
