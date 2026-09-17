## The Metacraft docs token layer ships FROM the design system -- this file is a
## thin re-export so this consumer's `build.nim`/`dev.nim` keep importing
## `./theme_tokens` unchanged. Edit the tokens in the
## `codetracer-design-system` repository (or via the live design-system
## editor, `just design`), never here.
##
## The module is `metacraft_docs_theme`, supplied by
## `codetracer-design-system/nim` -- which is why that repository is one of the
## nine entries in `../sibling-paths.txt` even though nothing else in RunQuota
## has ever needed it. Omitting it from the path set is not a visual
## regression, it is `cannot open file: metacraft_docs_theme`.
import metacraft_docs_theme
export metacraft_docs_theme
