#!/usr/bin/env bash
set -euo pipefail

if command -v nimpretty >/dev/null 2>&1; then
  find apps libs tests -type f -name '*.nim' -print0 | xargs -0 nimpretty
fi

# flake.nix is formatted with nixfmt. Its absence is never skipped in silence:
# on Windows it is a known platform gap and is reported as one; anywhere else
# the dev shell (flake or repro) provides it, so a missing nixfmt is an
# environment that is not the dev shell, and formatting stops.
if command -v nixfmt >/dev/null 2>&1; then
  nixfmt flake.nix
elif command -v nixfmt-rfc-style >/dev/null 2>&1; then
  nixfmt-rfc-style flake.nix
else
  case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN*)
    echo "format: flake.nix NOT formatted: nixfmt has no Windows build." >&2
    echo "  Upstream publishes only a Linux x86_64 binary, and its executable" >&2
    echo "  depends on the Haskell 'unix' package, which does not build on" >&2
    echo "  Windows (reprobuild-packages: packages/interfaces/nixfmt)." >&2
    echo "  Format flake.nix from a Linux or macOS dev shell." >&2
    ;;
  *)
    echo "format: nixfmt is not on PATH; run this from the dev shell" >&2
    echo "  (nix develop, or repro shell)." >&2
    exit 1
    ;;
  esac
fi
