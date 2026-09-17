## runquota/docs/book-isonim -- this site's own `DocsConfig`.
##
## The RunQuota book: user-facing documentation for the lease coordinator, its
## daemon, its CLI and its observation store. It is a consumer of the
## `isonim-docs` static-site framework, themed with the shared Metacraft docs
## theme (`theme_tokens.nim`, which re-exports `metacraft_docs_theme` from
## `codetracer-design-system/nim`).
##
## WHAT THIS BOOK IS NOT. `AGENTS.md` and the notes under `docs/` are written
## for contributors and agents working ON RunQuota; they describe boundaries,
## invariants and milestones, and they change with the implementation. The
## content here is written for somebody USING RunQuota -- an operator
## provisioning a host, a developer whose build sits behind an admission
## decision -- and it changes when the observable surface changes. The two have
## different audiences and different lifetimes, which is why the agent notes
## are not copied in here.
##
## DELIBERATELY MINIMAL, AND WHY. CodeTracer's book configures a logo, header
## links, sidebar social links and a "need some help?" footer block, each
## pointing at an asset vendored into its `static/` tree from the design
## system. RunQuota has no such assets and no published support pages, so
## every one of those fields is left at its default rather than filled with a
## path that would 404. Add them when there is something real behind them.

import core/config
import core/base_path

const docsSiteOrigin* = "https://metacraft-labs.github.io/runquota"
  ## The canonical origin the sitemap, `robots.txt` and the `og:`/canonical
  ## URLs are built against.
  ##
  ## PROVISIONAL. RunQuota has no published documentation site yet, and this
  ## is the address a GitHub Pages deploy from this repository would land on.
  ## It is here because the framework needs an absolute origin to emit
  ## canonical URLs at all, not because the site is live; change it in one
  ## place when a home is chosen, and nothing else in the book has to move.

proc bookDocsConfig*(basePath = ""): DocsConfig =
  ## This book's `DocsConfig`. `basePath` is the URL prefix the build is hosted
  ## under (`""` = the site root); it is normalized by the framework's
  ## `normalizeBasePath`, so `"nightly"`, `"/nightly"` and `"/nightly/"` are
  ## all accepted.
  let base = normalizeBasePath(basePath)
  DocsConfig(
    siteTitle: "RunQuota",
    siteDescription: "Documentation for RunQuota -- the host-wide lease " &
      "coordinator that keeps a machine from being oversubscribed.",
    defaultRoute: "/",
    stylesheetHref: "/assets/style.css",
    # Absolute canonical/og/sitemap URLs must carry the channel prefix too --
    # `basePath` only rewrites the root-relative URLs.
    baseUrl: docsSiteOrigin & base,
    basePath: base,
    # The sidebar's top-level sections, in READING order. Without this the
    # framework sorts sections alphabetically, which would file `reference`
    # ahead of `usage_guide` and both ahead of `getting_started`.
    sectionOrder: @["getting_started", "usage_guide", "reference"],
    footerHtml: "Built by <a href=\"https://github.com/metacraft-labs\">metacraft-labs</a>",
    # Ship + inject the compiled client bundle on every page, so the theme
    # toggle, live search and sidebar collapse are live. The bundle is
    # `src/main.nim`; the asset-hash pass rewrites this placeholder to the
    # cache-busted filename.
    appScriptHref: defaultAppScriptUrl,
    # Render every sidebar section expanded, so the article links are visible
    # and navigable on a plain page load before/without the client JS.
    expandAllNavSections: true,
    # One theme toggle, in the sidebar-bottom pill rather than the header --
    # this book configures no header links, so a header carrying nothing but a
    # toggle glyph would be the only thing in it.
    sidebarThemeToggle: true,
  )
