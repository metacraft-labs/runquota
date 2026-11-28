#!/usr/bin/env bash
# Every Justfile recipe is either run by a workflow or documented as not run
# there, with the reason.
#
# A test recipe that no workflow runs asserts nothing: `just test-release`,
# `just test-dev-shell` and `just verify-package` each sat in this Justfile,
# described as gates, while `.github/workflows/` never called them, and the
# release-mode suite had been failing by hand meanwhile. Nothing here noticed,
# because a recipe is only a name until something invokes it. The table in
# `docs/ci.md` (between the `recipe-schedule` markers) classifies every
# recipe, and this script holds the table to the Justfile and the workflows:
#
#   ci      the workflow(s) named in "Runs in" contain the recipe's signature:
#           `just <recipe>` by default, or the command in "Signature", which
#           the recipe's own body must also contain (a workflow that calls the
#           script directly, without `just`).
#   within  the recipe's signature is part of the body of the recipe named in
#           "Runs in", and that recipe is itself `ci`. `just lint` runs
#           `check_repo_requirements.sh`, so `check-repo-requirements` needs
#           no workflow step of its own.
#   alias   the recipe only runs the recipe named in "Runs in", which must be
#           classified too.
#   tool, bench, manual
#           not run by CI. "Notes" must say why. `manual` is a gate a person
#           runs; the metacraft-pm CI-Test-Coverage ground rules allow one only
#           with the reason recorded here.
#
# Asserted, besides the table itself:
#   1. Every recipe has exactly one row, and every row names a recipe.
#   2. Negative controls: the checker fails on a recipe without a row, on a
#      `ci` row whose workflow does not run the recipe, and on a `within` row
#      whose host recipe is not run by CI. A checker that passed those would
#      pass the state this script exists to stop.
#
# The backticks in single-quoted strings below are Markdown, not command
# substitutions.
# shellcheck disable=SC2016
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

BEGIN_MARK='<!-- recipe-schedule:begin -->'
END_MARK='<!-- recipe-schedule:end -->'
US=$'\x1f'

# Recipe names declared in a Justfile, one per line. A declaration is an
# unindented `name [params]:` that is not an assignment (`:=`) or a setting.
justfile_recipes() {
  awk '
    /^set / { next }
    /^[A-Za-z][A-Za-z0-9_-]*([ \t][^:=]*)?:([^=]|$)/ {
      name = $0; sub(/[ \t:].*/, "", name); print name
    }' "$1"
}

# The declaration line and indented body of one recipe.
recipe_text() {
  awk -v want="$2" '
    function decl_name(line,   n) { n = line; sub(/[ \t:].*/, "", n); return n }
    /^[A-Za-z][A-Za-z0-9_-]*([ \t][^:=]*)?:([^=]|$)/ && !/^set / {
      inside = (decl_name($0) == want)
      if (inside) print
      next
    }
    /^[ \t]/ { if (inside) print; next }
    { inside = 0 }' "$1"
}

# The table rows as fields separated by the ASCII unit separator (0x1f):
# recipe, class, runs-in, signature, notes. Not a tab: `read` collapses runs of
# a whitespace IFS character, so an empty cell would shift every later field.
# Backticks are stripped from every field but the notes.
table_rows() {
  awk -v b="$BEGIN_MARK" -v e="$END_MARK" -v FS_OUT="$US" '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    function bare(s) { s = trim(s); gsub(/`/, "", s); return s }
    $0 == b { on = 1; next }
    $0 == e { on = 0; next }
    on && /^\| *`/ {
      n = split($0, f, "|")
      if (n < 7) { print "MALFORMED" FS_OUT $0; next }
      print bare(f[2]) FS_OUT bare(f[3]) FS_OUT bare(f[4]) FS_OUT bare(f[5]) FS_OUT trim(f[6])
    }' "$1"
}

# Check one tree. Prints each failure and returns the number found.
check_tree() {
  local root="$1"
  local justfile="$root/Justfile" doc="$root/docs/ci.md" workflows="$root/.github/workflows"
  local failures=0
  bad() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }

  [ -f "$justfile" ] || { bad "no Justfile at $justfile"; return "$failures"; }
  [ -f "$doc" ] || { bad "no $doc"; return "$failures"; }
  if ! grep -qxF "$BEGIN_MARK" "$doc" || ! grep -qxF "$END_MARK" "$doc"; then
    bad "$doc has no recipe-schedule table markers"
    return "$failures"
  fi

  local recipes rows
  recipes="$(justfile_recipes "$justfile")"
  rows="$(table_rows "$doc")"
  # An empty sweep would pass every per-row rule below.
  [ "$(printf '%s\n' "$recipes" | grep -c .)" -ge 2 ] || bad "the Justfile yielded fewer than two recipes"
  [ "$(printf '%s\n' "$rows" | grep -c .)" -ge 2 ] || bad "$doc yielded fewer than two table rows"

  local dup
  dup="$(printf '%s\n' "$rows" | cut -d"$US" -f1 | sort | uniq -d)"
  [ -z "$dup" ] || bad "recipes with more than one row in docs/ci.md: $(tr '\n' ' ' <<<"$dup")"

  local r
  for r in $recipes; do
    printf '%s\n' "$rows" | cut -d"$US" -f1 | grep -qxF "$r" ||
      bad "recipe '$r' is in no row of docs/ci.md: add it to a workflow, or say there why CI does not run it"
  done

  local recipe class runs sig notes body host_class wf found
  while IFS="$US" read -r recipe class runs sig notes; do
    [ -n "$recipe" ] || continue
    if [ "$recipe" = MALFORMED ]; then bad "malformed row in docs/ci.md: $class"; continue; fi
    printf '%s\n' "$recipes" | grep -qxF "$recipe" ||
      { bad "docs/ci.md classifies '$recipe', which the Justfile does not declare"; continue; }
    body="$(recipe_text "$justfile" "$recipe")"
    if [ -n "$sig" ] && ! grep -qF -- "$sig" <<<"$body"; then
      bad "'$recipe': its body does not contain the signature '$sig'"
    fi
    case "$class" in
      ci)
        [ -n "$runs" ] || { bad "'$recipe' is ci but names no workflow"; continue; }
        found=0
        for wf in ${runs//,/ }; do
          [ -f "$workflows/$wf" ] || { bad "'$recipe': no workflow $wf"; continue; }
          found=$((found + 1))
          if [ -n "$sig" ]; then
            grep -qF -- "$sig" "$workflows/$wf" || bad "'$recipe': $wf does not run '$sig'"
          else
            grep -qE "just ${recipe}([[:space:]\"']|\$)" "$workflows/$wf" ||
              bad "'$recipe': $wf does not run 'just $recipe'"
          fi
        done
        [ "$found" -gt 0 ] || bad "'$recipe' is ci but none of its workflows exists"
        ;;
      within)
        [ -n "$sig" ] || bad "'$recipe' is within '$runs' but states no signature"
        host_class="$(printf '%s\n' "$rows" | awk -F"$US" -v h="$runs" '$1 == h { print $2 }')"
        [ "$host_class" = ci ] || bad "'$recipe' runs within '$runs', which is not run by CI (class '${host_class:-none}')"
        if [ -n "$sig" ] && ! recipe_text "$justfile" "$runs" | grep -qF -- "$sig"; then
          bad "'$recipe': recipe '$runs' does not run '$sig'"
        fi
        ;;
      alias)
        printf '%s\n' "$rows" | cut -d"$US" -f1 | grep -qxF "$runs" || bad "'$recipe' aliases '$runs', which has no row"
        if ! head -n1 <<<"$body" | grep -qE "^${recipe}:[[:space:]]+${runs}[[:space:]]*\$" &&
          ! grep -qE "^[[:space:]]+just ${runs}([[:space:]]|\$)" <<<"$body"; then
          bad "'$recipe' is an alias but does not just run '$runs'"
        fi
        ;;
      tool | bench | manual)
        [ -n "$notes" ] || bad "'$recipe' is $class and CI does not run it, but docs/ci.md says nothing about why"
        ;;
      *) bad "'$recipe' has unknown class '$class' (ci, within, alias, tool, bench, manual)" ;;
    esac
  done <<<"$rows"

  return "$failures"
}

status=0
check_tree "$REPO" || status=$?
[ "$status" -eq 0 ] || { echo "FAIL: $status recipe-schedule problem(s); see docs/ci.md" >&2; exit 1; }
echo "ok: every Justfile recipe is run by a workflow or documented in docs/ci.md as not run there"

# Negative controls, over a minimal tree that is correct until one thing is
# broken. Each broken copy must FAIL.
control="$(mktemp -d)"
trap 'rm -rf "$control"' EXIT
make_tree() {
  rm -rf "$control/t"
  mkdir -p "$control/t/docs" "$control/t/.github/workflows"
  printf '%s\n' 'set shell := ["bash", "-c"]' 'X := "y"' '' \
    'lint:' '    bash scripts/a.sh' '    bash scripts/b.sh' '' \
    'check-a:' '    bash scripts/a.sh' '' \
    'test-gate:' '    bash scripts/gate.sh' > "$control/t/Justfile"
  printf '%s\n' "$BEGIN_MARK" \
    '| Recipe | Class | Runs in | Signature | Notes |' '|---|---|---|---|---|' \
    '| `lint` | ci | `ci.yml` | | |' \
    '| `check-a` | within | `lint` | `bash scripts/a.sh` | |' \
    '| `test-gate` | ci | `ci.yml` | | |' "$END_MARK" > "$control/t/docs/ci.md"
  printf '%s\n' 'jobs:' '  j:' '    steps:' '      - run: just lint' '      - run: just test-gate' \
    > "$control/t/.github/workflows/ci.yml"
}
expect_fail() {
  local what="$1"
  if (check_tree "$control/t") 2>/dev/null; then
    echo "FAIL: control: the checker passes $what" >&2
    exit 1
  fi
}
make_tree
(check_tree "$control/t") 2>/dev/null || { echo "FAIL: control: the checker rejects a correct tree" >&2; exit 1; }
make_tree; sed -i '/just test-gate/d' "$control/t/.github/workflows/ci.yml"
expect_fail "a ci recipe that no workflow runs"
make_tree; sed -i '/`test-gate`/d' "$control/t/docs/ci.md"
expect_fail "a recipe with no row"
make_tree; sed -i 's/^| `lint` | ci | `ci.yml` | | |$/| `lint` | tool | | | a reason |/' "$control/t/docs/ci.md"
expect_fail "a within recipe whose host CI does not run"
make_tree; sed -i 's/^| `test-gate` | ci | `ci.yml` | | |/| `test-gate` | manual | | | |/' "$control/t/docs/ci.md"
expect_fail "a manual recipe with no reason"
echo "ok: the checker fails an unscheduled recipe, a missing row, an unscheduled host and an unexplained manual recipe"
