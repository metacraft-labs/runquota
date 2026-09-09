#!/usr/bin/env bash
set -euo pipefail

source_root=${1:?supply a source root}
# Check symlink targets, not the link's nominal 0777 mode. Capture find's
# status directly so traversal errors or a short-reading pipe cannot pass.
if ! writable_path=$(find -L "$source_root" \
    \( -perm -0200 -o -perm -0020 -o -perm -0002 \) -print -quit); then
  printf 'cannot inspect immutable source snapshot: %s\n' "$source_root" >&2
  exit 1
fi
if [ -n "$writable_path" ]; then
  printf 'immutable source snapshot contains a writable path: %s\n' "$writable_path" >&2
  exit 1
fi
