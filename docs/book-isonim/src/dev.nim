## Live-reloading dev server for the RunQuota book (book-isonim consumer).
##
## Serves this book's own `content/` plus its themed assets (`assets/style.css`
## with the Metacraft token CSS prepended, and the `static/` tree -- the same
## dirs `build.nim` maps into `public/assets/`) over HTTP, and watches
## `content/` so any edit hot-reloads every open tab via the framework's
## `dev_server` WebSocket live-reload channel.
##
## Driven by `just dev-docs` (server) + `just open-docs` (browser); the
## optional first argument is the port (default 8000) and the second the host
## (default loopback).

import std/[os, strutils, asyncdispatch]
import docs_scaffold
import ./docs_config
import ./theme_tokens

export docs_scaffold

proc newDocsDevServer*(contentDir = "content";
                       assetsDirs = @["assets", "static"]): DevServer =
  ## This book's themed live-reload dev server via the framework `docsDevServer`
  ## scaffold, wiring the shared design-system token provider for hot reload.
  ## Exposed so a test drives the exact `just dev-docs` wiring without binding a
  ## socket.
  docsDevServer(bookDocsConfig(), contentDir = contentDir, assetsDirs = assetsDirs,
                tokensCssProvider = (proc(): string = docsTokensCssLive()),
                watchPaths = @[docsDesignSystemPath],
                clientEntry = "src/main.nim")

when isMainModule:
  let port = if paramCount() >= 1: parseInt(paramStr(1)) else: 8000
  # host: 2nd arg or AH_DEV_HOST env; default loopback (pass 0.0.0.0 for LAN).
  let host =
    if paramCount() >= 2: paramStr(2)
    elif existsEnv("AH_DEV_HOST"): getEnv("AH_DEV_HOST")
    else: "127.0.0.1"
  let server = newDocsDevServer()
  stdout.writeLine "RunQuota book dev server -> http://" & host & ":" & $port &
    "  (watching content/ + shared design system, live reload on; Ctrl-C to stop)"
  stdout.flushFile()
  waitFor serve(server, port, host = host)
