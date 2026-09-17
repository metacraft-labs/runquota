## runquota/docs/book-isonim -- thin SSG entry.
##
## Calls the framework's `buildDocsSite` scaffold with this site's `content/`
## dir and its own `DocsConfig`, passing NO explicit manifest -- letting the
## framework's default (`buildManifestFromContent`) auto-discover the route
## table, and its non-alphabetical nav order via each page's `order:` front
## matter, from `content/`.
##
## The shared Metacraft docs token layer
## (`theme_tokens.metacraftDocsTokensCss`) is emitted to CSS and PREPENDED onto
## `assets/style.css`, and anything under `static/` is copied verbatim into
## `public/assets/` AFTER the hash/purge pass so the stylesheet's
## `url(/assets/...)` refs resolve to real files.
##
## `clientEntry` compiles `src/main.nim` with `nim js` into the hashed
## `assets/app.js`. That nested compile is a CHILD `nim` process, and it
## inherits the sibling `--path` set only through `nim.cfg` -- which is why the
## path set has to be a real file on disk (written by `just nim-cfg`, or by
## `repro.nim`'s `docs-book-nim-cfg` action) rather than flags on this
## command line.

when defined(js):
  {.error: "build.nim is a C-target (SSG) entry; not for the JS target".}

import std/os
import docs_scaffold
import core/base_path
import ./docs_config
import ./theme_tokens

const basePathEnvVar* = "RUNQUOTA_DOCS_BASE_PATH"
  ## The URL prefix this build is published under: unset/empty for the site
  ## root, `"/nightly"` for a nightly channel served from a subdirectory. An
  ## env var rather than a CLI flag because the build runs through
  ## `just build` -> `nim c -r`, which would otherwise have to forward
  ## arguments through two layers.

when isMainModule:
  # Normalized here so the value that reaches the config and the log line is
  # the same one.
  let channelBase = normalizeBasePath(getEnv(basePathEnvVar))
  let n = buildDocsSite(bookDocsConfig(channelBase),
                        docsTokensCss = metacraftDocsTokensCss(),
                        clientEntry = "src/main.nim")
  echo "SSG: rendered ", n, " static pages into ./public/",
    (if channelBase.len > 0: " (hosted under " & channelBase & ")" else: "")
