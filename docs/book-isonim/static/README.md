# `static/`

Everything in this directory is copied **verbatim** into `public/assets/` after
the static-site generator's hash-and-purge pass, so a stylesheet's
`url(/assets/...)` and a page's `/assets/...` image references resolve to real
files.

It is empty on purpose. The RunQuota book currently ships no logo, fonts or
screenshots of its own: the type and colour come from the shared Metacraft docs
theme (see `../src/theme_tokens.nim`), and no page references an image. Add
binaries here when a page needs one — and note that the book's content suite
resolves every internal link, so a page may only reference something that
exists.
