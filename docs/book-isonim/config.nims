# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
# RunQuota docs -- Nim path/define switching for isonim-docs SSG.

import std/os

let here = currentSourcePath().parentDir()      ## .../runquota/docs/book-isonim
let siblingRoot = here / "../../.."              ## sibling-checkout fallback root

proc pathFor(envName, fallback: string): string =
  if existsEnv(envName) and getEnv(envName).len > 0: getEnv(envName)
  else: fallback

let isonimSrc      = pathFor("RUNQUOTA_DOCS_ISONIM_SRC",        siblingRoot / "isonim/src")
let isonimDocsSrc  = pathFor("RUNQUOTA_DOCS_ISONIM_DOCS_SRC",   siblingRoot / "isonim-docs/src")
let nimEverywhere  = pathFor("RUNQUOTA_DOCS_NIM_EVERYWHERE_SRC", siblingRoot / "nim-everywhere/src")
let nimFaststreams = pathFor("RUNQUOTA_DOCS_NIM_FASTSTREAMS",   siblingRoot / "nim-faststreams")
let nimStew        = pathFor("RUNQUOTA_DOCS_NIM_STEW",          siblingRoot / "nim-stew")
let isonimVendor   = pathFor("RUNQUOTA_DOCS_ISONIM_VENDOR",     siblingRoot / "isonim/vendor")
let designSystem   = pathFor("RUNQUOTA_DOCS_DESIGN_SYSTEM",     siblingRoot / "codetracer-design-system")

switch("path", isonimSrc)
switch("path", isonimDocsSrc)
switch("path", designSystem / "nim")
switch("path", nimEverywhere)
switch("path", nimFaststreams)
switch("path", nimStew)
switch("path", isonimVendor / "chronicles")
switch("path", isonimVendor / "serialization")
switch("path", isonimVendor / "json_serialization")
switch("define", "chronicles_sinks=textlines[stderr]")
switch("define", "chronicles_runtime_filtering=on")
switch("define", "chronicles_log_level=TRACE")
