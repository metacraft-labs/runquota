## Workflow admission is a source contract, so read the real workflow files.
## No mocks or CI runs are needed: GitHub applies these selectors before any
## job starts. Check complete event blocks, failing closed if their shape
## changes, rather than counting branch names elsewhere (action @main refs
## and PR head branches have different meanings).

import std/[os, strutils, unittest]

const workflowDir = currentSourcePath().parentDir().parentDir().parentDir() /
  ".github" / "workflows"

proc eventBlock(workflow: string): string =
  ## The top-level `on` mapping ends at the next non-comment top-level key.
  ## These workflows deliberately use an unquoted, block-form `on:` key;
  ## changing that representation requires updating this contract too.
  var found = false
  for line in workflow.splitLines():
    if line.strip().len == 0 or line.strip().startsWith("#"):
      continue
    if line == "on:":
      doAssert not found, "duplicate on: mapping"
      found = true
    elif found and line.len > 0 and line[0] notin {' ', '#'}:
      break
    if found:
      result.add line & "\n"
  doAssert found, "workflow has no on: mapping"
  result = result.strip()

suite "workflow admission":
  test "documentation publishes only from dev and stable pushes":
    let workflow = readFile(workflowDir / "docs-pages.yml")
    check eventBlock(workflow) == """on:
  push:
    branches: [dev, stable]
    paths:
      - "docs/book-isonim/**"
      - ".github/workflows/docs-pages.yml"
  workflow_dispatch:"""

  test "documentation retains the full build and deployment":
    let workflow = readFile(workflowDir / "docs-pages.yml")
    for required in [
      "  build:", "actions/configure-pages@v5",
      "nix develop ./docs/book-isonim --command bash -c '",
      "nim c -r --hints:off -o:build/build src/build.nim",
      "actions/upload-pages-artifact@v3", "path: docs/book-isonim/public",
      "  deploy:", "needs: build", "actions/deploy-pages@v4",
    ]:
      checkpoint required
      check required in workflow

  test "ordinary CI push branches follow the product branch model":
    check eventBlock(readFile(workflowDir / "ci.yml")) == """on:
  workflow_dispatch:
  merge_group:
    types: [checks_requested]
  push:
    branches: [dev, stable]
  pull_request:
    branches-ignore: [agents]"""

  test "reprobuild CI push and PR bases follow the product branch model":
    check eventBlock(readFile(workflowDir / "ci-reprobuild.yml")) == """on:
  workflow_dispatch:
  merge_group:
    types: [checks_requested]
  push:
    branches: [dev, stable]
  pull_request:
    branches: [dev, stable]"""
