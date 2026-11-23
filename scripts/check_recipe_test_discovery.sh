#!/usr/bin/env bash
# repro.nim discovers this project's tests from its own root, and every test
# program it discovers has a unique name.
#
# A consumer such as CodeTracer evaluates repro.nim as a cross-repo producer
# from its own root. Discovery that walked the working directory (`walkDir("libs")`,
# `walkDirRec(root)` over "tests" / "libs") read the consumer's vendored
# libraries instead, found nim-faststreams' and nim-serialization's
# `tests/test_readme_examples.nim`, and the provider stopped every CodeTracer
# build with "Duplicate test binary name: test_readme_examples". Asserted:
#
#   1. No directory walk in repro.nim takes a bare relative path literal (or
#      a loop variable over relative names) as its root.
#   2. Negative control: the matcher flags the lines that failed.
#   3. The test programs discovery would find here have unique names, as the
#      recipe's `doAssert name notin names` requires.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
fail() { echo "FAIL: $*" >&2; exit 1; }

matcher() { grep -nE 'walkDir(Rec)?[(](["]|root\b|[a-z]+[)])' "$1" || true; }

hits="$(matcher repro.nim)"
[ -z "$hits" ] || fail "repro.nim walks a directory relative to the working directory; walk projectRootPath / <dir>:
$hits"
echo "ok: repro.nim walks no directory relative to the working directory"

control="$(mktemp)"; trap 'rm -f "$control"' EXIT
printf '%s\n' '    for kind, path in walkDir("libs"):' '      for source in walkDirRec(root):' > "$control"
[ "$(matcher "$control" | wc -l)" = 2 ] || fail "the matcher does not flag the working-directory walks it exists to catch"
echo "ok: the matcher flags working-directory walks"

dups="$( { find tests -name 't*.nim' 2>/dev/null; find libs -path '*/tests/t*.nim' 2>/dev/null; } \
  | xargs -r -n1 basename | sed 's/\.nim$//' | sort | uniq -d )"
[ -z "$dups" ] || fail "test programs share a name: $dups"
echo "ok: every discovered test program has a unique name"
