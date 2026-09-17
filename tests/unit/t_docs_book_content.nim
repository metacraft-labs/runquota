## The RunQuota book's content graph: front matter, section registration and
## internal links.
##
## WHY THIS TEST EXISTS IN THE REPOSITORY'S SUITE rather than only in the
## book's own. The book is rendered by the `isonim-docs` static-site framework,
## which lives in a SIBLING repository that a normal RunQuota workspace does
## not check out. Everything that needs the framework -- the SSG, the dev
## server, the rendered `public/` tree -- can only be exercised in a workspace
## that has it. The content graph does not need it: a page's front matter, the
## set of sections, and whether a `[text](/route)` link points at a page that
## exists are all statements about files in THIS repository, and they are the
## statements most likely to be wrong, because they are the ones a writer
## changes. So they are asserted here, where they run on every `just test`.
##
## NO MOCKS. Real `.md` files under `docs/book-isonim/content`, read from disk.
## There is nothing to mock: the subject is the files.
##
## WHAT THIS DELIBERATELY DOES NOT CLAIM. Passing here does not mean the book
## renders. It means no page is missing front matter, no section is unregistered
## and no internal link is dangling -- three specific ways a rendered book is
## wrong that do not need a renderer to detect. The rendering itself is
## verified by the book's own suite, in a workspace that has the framework.
##
## THE SLUG RULE IS THIS TEST'S OWN, and it is the one place it could be wrong
## about the framework. Anchors are matched against headings slugified the
## common way (lowercased, runs of non-alphanumerics collapsed to `-`,
## trimmed). If the framework ever slugifies differently, this check goes red
## on correct content -- which is a visible, fixable failure rather than a
## silent one, and is why it is called out here rather than buried.

import std/[algorithm, os, sequtils, sets, strutils, tables, unittest]

const
  RepoRoot = currentSourcePath().parentDir().parentDir().parentDir()
  BookDir = RepoRoot / "docs" / "book-isonim"
  ContentDir = BookDir / "content"
  DocsConfigPath = BookDir / "src" / "docs_config.nim"

type
  Page = object
    path: string        ## Absolute path to the `.md` file.
    route: string       ## The root-relative route it is published at.
    section: string     ## "" for a root-level page.
    title: string
    order: string       ## As written; "" when absent.
    body: string

proc slugify(heading: string): string =
  ## Lowercase, non-alphanumerics collapsed to `-`, trimmed. See the header:
  ## this is this test's own rule, stated once.
  var lastWasDash = true  # suppresses a leading dash
  for ch in heading:
    if ch.isAlphaNumeric:
      result.add ch.toLowerAscii
      lastWasDash = false
    elif not lastWasDash:
      result.add '-'
      lastWasDash = true
  while result.len > 0 and result[^1] == '-':
    result.setLen(result.len - 1)

proc frontMatterField(text, field: string): string =
  ## The value of `field:` in the leading `---` block, or "" if absent.
  let lines = text.splitLines()
  if lines.len == 0 or lines[0].strip() != "---":
    return ""
  for i in 1 ..< lines.len:
    let line = lines[i]
    if line.strip() == "---":
      break
    let colon = line.find(':')
    if colon > 0 and line[0 ..< colon].strip() == field:
      return line[colon + 1 .. ^1].strip()

proc routeFor(relPath: string): string =
  ## `index.md` -> the directory's own route; anything else -> `/dir/name`.
  let withoutExt = relPath.changeFileExt("")
  let unixed = withoutExt.replace('\\', '/')
  if unixed == "index":
    return "/"
  if unixed.endsWith("/index"):
    return "/" & unixed[0 ..< unixed.len - "/index".len]
  "/" & unixed

proc loadPages(): seq[Page] =
  for path in walkDirRec(ContentDir):
    if path.splitFile().ext != ".md":
      continue
    let rel = relativePath(path, ContentDir).replace('\\', '/')
    let text = readFile(path)
    let parts = rel.split('/')
    result.add Page(
      path: path,
      route: routeFor(rel),
      section: (if parts.len > 1: parts[0] else: ""),
      title: frontMatterField(text, "title"),
      order: frontMatterField(text, "order"),
      body: text)
  result.sort(proc(a, b: Page): int = cmp(a.route, b.route))

proc configuredSectionOrder(): seq[string] =
  ## The `sectionOrder: @["a", "b"]` list, read out of `src/docs_config.nim`.
  ## Parsed rather than duplicated: the point of the clause below is that the
  ## content and the config agree, so one of them has to be the source.
  let text = readFile(DocsConfigPath)
  let at = text.find("sectionOrder:")
  doAssert at >= 0, "docs_config.nim no longer declares a sectionOrder"
  let open = text.find('[', at)
  let close = text.find(']', open)
  doAssert open > 0 and close > open, "sectionOrder is not a literal list"
  for raw in text[open + 1 ..< close].split(','):
    let item = raw.strip().strip(chars = {'"'})
    if item.len > 0:
      result.add item

proc internalLinks(body: string): seq[string] =
  ## Every `](/...)` target in the page, link text discarded.
  var i = 0
  while true:
    let at = body.find("](/", i)
    if at < 0:
      break
    let close = body.find(')', at)
    if close < 0:
      break
    result.add body[at + 2 ..< close]
    i = close + 1

suite "RunQuota book content":
  let pages = loadPages()

  test "the book has content at all":
    # A guard against every other clause below passing vacuously over an empty
    # sequence, which is exactly what a mistyped ContentDir would produce.
    check pages.len >= 8
    check "/" in pages.mapIt(it.route)

  test "every page declares a title and an order":
    for page in pages:
      checkpoint page.path
      check page.title.len > 0
      check page.order.len > 0

  test "every section is registered in sectionOrder":
    # An unregistered section is not an error the framework reports -- it sorts
    # ALPHABETICALLY, which silently files a new section ahead of Getting
    # Started and is only ever noticed by looking at the rendered sidebar.
    let configured = configuredSectionOrder().toHashSet
    check configured.len > 0
    var seen = initHashSet[string]()
    for page in pages:
      if page.section.len == 0:
        continue
      checkpoint page.path
      check page.section in configured
      seen.incl page.section
    # And the other direction: a section configured but emptied out would put a
    # heading in the sidebar with nothing under it.
    for section in configured:
      checkpoint section
      check section in seen

  test "orders are unique within a section":
    var bySection = initTable[string, HashSet[string]]()
    for page in pages:
      checkpoint page.path
      let existing = bySection.mgetOrPut(page.section, initHashSet[string]())
      check page.order notin existing
      bySection[page.section].incl page.order

  test "every internal link points at a page that exists":
    let routes = pages.mapIt(it.route).toHashSet
    for page in pages:
      for link in internalLinks(page.body):
        let hash = link.find('#')
        let route = (if hash >= 0: link[0 ..< hash] else: link)
        checkpoint page.path & " -> " & link
        check route in routes

  test "every link anchor points at a heading that exists":
    var headingsByRoute = initTable[string, HashSet[string]]()
    for page in pages:
      var slugs = initHashSet[string]()
      for line in page.body.splitLines():
        if line.startsWith("#"):
          slugs.incl slugify(line.strip(chars = {'#', ' '}))
      headingsByRoute[page.route] = slugs
    for page in pages:
      for link in internalLinks(page.body):
        let hash = link.find('#')
        if hash < 0:
          continue
        let route = link[0 ..< hash]
        let anchor = link[hash + 1 .. ^1]
        if route notin headingsByRoute:
          continue  # already failed in the clause above
        checkpoint page.path & " -> " & link
        check anchor in headingsByRoute[route]

  test "the book does not re-publish the contributor notes":
    # `AGENTS.md` and `docs/*.md` are written for people working ON RunQuota;
    # they describe boundaries, invariants and milestones, and they change with
    # the implementation. Pasting one in here would give it a second, silently
    # diverging copy with a different audience and a different lifetime. The
    # cheap, stable signal that it happened is a milestone marker.
    for page in pages:
      checkpoint page.path
      check "M13" notin page.body
      check "AGENTS.md" notin page.body
