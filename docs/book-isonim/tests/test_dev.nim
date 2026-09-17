## Protects the `just dev-docs` live-reload wiring for the RunQuota book:
## themed stylesheet (token CSS prepended) + branded, reload-injected pages
## over its content/assets/static, and a content edit firing a reload
## broadcast.
##
## NEEDS THE FRAMEWORK SIBLINGS. Unlike `tests/unit/t_docs_book_content.nim` in
## the repository root -- which asserts the content graph with nothing but
## `std` and therefore runs in any RunQuota workspace -- this file imports
## `../src/dev`, which reaches `isonim-docs`. It can only run where
## `sibling-paths.txt` fully resolves. See ../README.md.
##
## NO MOCKS. The second case drives a real directory on the real filesystem
## and a real file write, because the subject is a filesystem watcher: a stub
## clock or a stub directory would be exactly as happy with the watch removed.

import std/[unittest, os]
import ../src/dev   # newDocsDevServer + (re-exported) dev_server API

suite "RunQuota book dev server (themed live-reload wiring)":
  test "serves the themed stylesheet + branded, reload-injected home page":
    let ds = newDocsDevServer()
    let (hs, hct, home) = handleRoute(ds, "/")
    check hs == 200
    check hct == "text/html; charset=utf-8"
    check home.contains("RunQuota")
    check home.contains(defaultLiveReloadPath)
    let (cs, cct, css) = handleRoute(ds, "/assets/style.css")
    check cs == 200
    check cct == "text/css; charset=utf-8"
    check css.contains("--docs-")

  test "a content edit fires a live-reload broadcast":
    let tmp = getTempDir() / "runquota_book_devreload"
    removeDir(tmp); createDir(tmp)
    writeFile(tmp / "index.md", "---\ntitle: Home\n---\n# Home\n")
    let ds = newDocsDevServer(contentDir = tmp)
    let q = ds.hub.subscribe()
    check q[].len == 0
    writeFile(tmp / "index.md", "---\ntitle: Home\n---\n# Home edited\n")
    check ds.pollForChanges().len == 1
    check q[] == @[reloadMessage]
