#!/usr/bin/env bash
# The commit-time `just lint` (`.pre-commit-config.yaml`, hook `just-lint`).
#
# The lint's verdict depends on its tools (nim, just, shellcheck, ...), so
# where Nix is available they come from the dev shell flake.nix pins, never
# from the PATH the commit happens to be made from. The script enters that
# shell itself, which is what lets a linked worktree that never entered its
# dev shell commit at all: the hook is shared by every worktree, the shell is
# not.
#
# Where there is no Nix (a Windows repro shell, which runs this hook through
# prek), the repro shell is the environment that pins the tools, and the
# commit is made from inside it. There `just lint` runs directly.
#
# The shell is entered with RUNQUOTA_DEV_SHELL_NO_HOOK_INSTALL set: a commit
# must not reinstall the hooks that are running it (flake.nix, `ownRepoOnly`).
#
# pre-commit stashes unstaged changes before it runs hooks, so the tree this
# lints is the tree being committed.
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if command -v nix >/dev/null 2>&1; then
	export RUNQUOTA_DEV_SHELL_NO_HOOK_INSTALL=1
	exec nix develop "$repo_root" --no-write-lock-file --command \
		just --justfile "$repo_root/Justfile" lint
fi
if command -v just >/dev/null 2>&1; then
	exec just --justfile "$repo_root/Justfile" lint
fi
echo "pre_commit_lint: neither nix nor just is on PATH, so 'just lint' cannot run." >&2
echo "pre_commit_lint: commit from a dev shell ('nix develop', or 'repro shell' on Windows)." >&2
exit 1
