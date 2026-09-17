# The RunQuota book — working on the user documentation

This is RunQuota's **user-facing documentation site**. The Markdown in
`content/` is rendered by the [isonim-docs](../../../isonim-docs) static-site
framework and themed by the shared Metacraft docs design system.

It is not the contributor documentation. `AGENTS.md` and the notes beside this
directory in `docs/` are written for people working **on** RunQuota — they
describe boundaries, invariants and milestones, and they change with the
implementation. The content here is written for somebody **using** RunQuota,
and it changes when the observable surface changes. Do not copy one into the
other; a test asserts that the book carries no milestone markers.

## ⚠ Read this first: the framework lives in sibling repositories

The book needs **nine sibling source trees** next to the RunQuota checkout, and
**most of them are not part of the RunQuota project manifest**. A normal
RunQuota workspace therefore cannot build this book at all. The list is
[`sibling-paths.txt`](./sibling-paths.txt), and it is the only copy of that
list — both `just nim-cfg` and `repro.nim`'s `docs-book-nim-cfg` action read
it.

Check where you stand:

```bash
just nim-cfg
```

It either writes `nim.cfg` and tells you the workspace root it resolved
against, or it names the first repository it could not find and exits 1
**without writing a partial config** — a half-populated path set turns into
`cannot open file: <some framework module>` from deep inside the generator,
which names a module instead of the checkout that is actually missing.

What has to be beside the RunQuota checkout: `isonim-docs`,
`codetracer-design-system`, `isonim`, `nim-everywhere`, `nim-faststreams` and
`nim-stew`. Adding them to the RunQuota project manifest is a workspace-wide
decision — `workspace project repo add` commits and pushes to the shared
manifest repository and changes every colleague's workspace — so it is not
something to do on the way past.

`nim.cfg` is git-ignored, and must stay that way: its contents are absolute
paths on one machine, and a committed copy would collide with the one the build
generates.

## Prerequisites

Every task except `just nim-cfg` runs inside **this book's own dev shell**,
which provides `nim`, `just` and `node`. The book consumes the
[isonim-docs](../../../isonim-docs) framework, so it reuses that framework's
self-contained dev shell — which declares isonim as its dependency. Nobody has
to `nix develop ../../../isonim`, and **nobody has to enter RunQuota's own dev
shell**: the book builds no RunQuota code and links nothing from `libs/`.

With **direnv** the shell activates on `cd` (see `./.envrc`):

```bash
cd runquota/docs/book-isonim
just dev-docs
```

Without direnv:

```bash
nix develop path:../../../isonim-docs -c just dev-docs
```

## Live preview, build, tests

```bash
just dev-docs                 # http://127.0.0.1:8000  (loopback only)
just dev-docs-lan             # same, reachable on your private LAN
just open-docs                # open the running server in a browser
just build                    # static build into public/
just serve-docs               # one-shot SSR preview (no live reload)
just test                     # content graph, then build, then the dev-server suite
```

The **first launch compiles** the dev server and pre-compiles the client JS
bundle (theme toggle, live search, sidebar collapse) — expect a minute before
it serves; after that, edits are instant. Default host is loopback; pass
`0.0.0.0` (or set `AH_DEV_HOST`) only on a trusted network, because it exposes
the unauthenticated docs to the LAN.

### The two test suites, and which one you can actually run

| Suite | Needs the siblings? | Where |
|---|---|---|
| Content graph — front matter, section registration, dangling links and anchors | **No.** `std` only. | `../../tests/unit/t_docs_book_content.nim` — runs on every `just test` in the repository root |
| Dev-server wiring — themed stylesheet, reload-injected pages, watch-fires-reload | **Yes.** | `tests/test_dev.nim` |

The content suite lives in the repository's own test tree deliberately: the
checks that catch a writer's mistakes must not be the ones that only run in a
workspace nobody has. `just test` here runs both, so a writer working in this
directory gets the same answer without changing directories.

## Adding a page

Drop a Markdown file with front matter into the right `content/<section>/`
folder:

```markdown
---
title: What the sidebar and the tab say
order: 3
---
```

Both fields are required and the content suite enforces it. `order` controls
the position within the section and must be unique inside it.

**A new top-level section also needs an entry in `sectionOrder` in
`src/docs_config.nim`.** Without one the framework sorts it *alphabetically*,
which silently files it ahead of Getting Started — a mistake only visible by
looking at the rendered sidebar, which is why the content suite fails on an
unregistered section instead.

Internal links are root-relative routes (`/usage_guide/cli`,
`/getting_started/concepts#estimate`). Every one of them is resolved against
the content tree by the suite, anchors included, so a renamed page cannot leave
a dead link behind.

## Where things live

| Path | What |
|------|------|
| `content/index.md` | The home page |
| `content/{getting_started,usage_guide,reference}/` | The three sections |
| `src/docs_config.nim` | Site title, origin, section order, chrome |
| `src/{build,dev,ssr,main,theme_tokens}.nim` | Build / serve / client entry points |
| `sibling-paths.txt` | The nine sibling trees — the single copy of that list |
| `sibling_paths.nim` | Its parser and resolver, shared with `repro.nim` |
| `write_nim_cfg.nim` | `just nim-cfg` |
| `static/` | Verbatim assets (currently empty — see its README) |

## Changing the look

The book is themed by the shared Metacraft docs design system, the same one the
other Metacraft docs sites use. `src/theme_tokens.nim` re-exports it; do not
edit tokens there. To tweak it visually:

```bash
just design                   # http://127.0.0.1:8080  (the shared theme editor)
```

Keep `just dev-docs` running in another shell — a token you **Save** in the
editor hot-reloads the book live, no rebuild.

## Building it through the build graph

`repro.nim` declares the book as build-graph edges rather than leaving it to a
script:

```bash
repro build docs-book
```

`docs-book-nim-cfg` writes the same `nim.cfg` `just nim-cfg` does, as a tracked
output; `docs-book-build` runs the generator with that file as a declared
input. So editing one `content/*.md` re-runs the generator and only what needs
a rendered `public/`, and the path set is a tracked input rather than a side
effect of one script that deletes it again.

**Both targets are absent from the graph entirely when the siblings are not
checked out.** That is the correct behaviour, not a bug: every other RunQuota
target has to resolve in a workspace that will never build this book. Confirm
it with

```bash
repro build --list-targets
```

— `docs-book` and `docs-book-nim-cfg` appear only when the nine trees are all
present.

## Deployment

There is none yet. `src/docs_config.nim` carries a provisional
`docsSiteOrigin`, and nothing in CI publishes this book. When it gets a home,
that constant and a deploy job are the only things that have to change.
