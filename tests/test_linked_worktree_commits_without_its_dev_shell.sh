#!/usr/bin/env bash
# A commit in a linked worktree of this repository is judged on its content,
# without that worktree's dev shell ever having been entered.
#
# Hooks live in the common git directory, so every worktree runs the hook the
# main checkout's dev shell installed. That hook used to be git-hooks.nix's
# pre-commit shim, whose `--config=.pre-commit-config.yaml` names a gitignored
# symlink only a dev-shell entry creates. In a fresh linked worktree it did not
# exist, so EVERY commit there was refused ("No .pre-commit-config.yaml file
# was found") whatever it contained. The config is now committed, so every
# worktree carries the rules, and the hook enters the dev shell itself for the
# tools (scripts/pre_commit_lint.sh).
#
# Asserted, from a scratch copy of this tree whose main checkout entered the
# dev shell once:
#   1. a linked worktree, never entered, commits a harmless change from an
#      environment without the dev shell's tools (no `just`, no
#      IN_NIX_SHELL), and the commit ran `just lint` rather than skipping it;
#   2. the same worktree's commit of an added `*.ct` recording is REFUSED, so
#      the hook that let (1) through is a live gate, not an absent one;
#   3. its commit of a change `just lint` rejects (an added `prek.toml`) is
#      REFUSED by the lint, so the lint in (1) ran rather than skipped.
#
# No mocks: the real flake, the real hook installer, the real pre-commit and
# the real hook repositories (fetched once into the user's pre-commit cache).
#
#   bash tests/test_linked_worktree_commits_without_its_dev_shell.sh
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="$(mktemp -d)"
trap 'chmod -R u+w "$SCRATCH" 2>/dev/null; rm -rf "$SCRATCH"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# THE TREE UNDER TEST is this checkout's working tree (tracked files plus
# untracked files that are not ignored), not its HEAD, so the test grades the
# change being made. It becomes the first commit of a scratch repository.
MAIN="$SCRATCH/main"
mkdir -p "$MAIN"
(cd "$REPO" && git ls-files -z --cached --others --exclude-standard |
  while IFS= read -r -d '' f; do [ -e "$f" ] || [ -L "$f" ] && printf '%s\0' "$f"; done |
  tar --null -T - -cf -) | tar -C "$MAIN" -xf -
git -C "$MAIN" init -q
git -C "$MAIN" add -A
git -C "$MAIN" -c user.name=t -c user.email=t@t commit -q --no-verify -m snapshot

# The main checkout enters its dev shell once: that installs the hooks into
# the common git directory, which every worktree shares.
(cd "$MAIN" && nix develop "$MAIN" --no-write-lock-file -c true) >"$SCRATCH/shell.log" 2>&1 ||
  { cat "$SCRATCH/shell.log" >&2; fail "the dev shell did not start in the main checkout"; }
[ -x "$MAIN/.git/hooks/pre-commit" ] ||
  { cat "$SCRATCH/shell.log" >&2; fail "entering the dev shell installed no pre-commit hook"; }

WT="$SCRATCH/wt"
git -C "$MAIN" worktree add -q --detach "$WT" HEAD

# AN ENVIRONMENT THAT NEVER ENTERED THE DEV SHELL: only git, nix, bash and
# coreutils on PATH. `just`, which the lint needs, must not be reachable, or
# the test would pass on a shell the caller happened to be in.
BIN="$SCRATCH/bin"
mkdir -p "$BIN"
for tool in git nix bash; do ln -s "$(command -v "$tool")" "$BIN/$tool"; done
CLEAN_PATH="$BIN:$(dirname "$(readlink -f "$(command -v env)")")"
outside_shell() {
  env -i HOME="$HOME" USER="${USER:-}" TMPDIR="${TMPDIR:-/tmp}" PATH="$CLEAN_PATH" \
    ${NIX_REMOTE:+NIX_REMOTE="$NIX_REMOTE"} ${XDG_CACHE_HOME:+XDG_CACHE_HOME="$XDG_CACHE_HOME"} \
    "$@"
}
if outside_shell bash -c 'command -v just' >/dev/null; then
  fail "precondition: 'just' is reachable outside the dev shell"
fi
[ ! -e "$WT/.pre-commit-config.yaml" ] || [ -n "$(git -C "$WT" ls-files .pre-commit-config.yaml)" ] ||
  fail "precondition: the fresh worktree has an untracked .pre-commit-config.yaml"

commit() {
  (cd "$WT" && outside_shell git -c user.name=t -c user.email=t@t commit -q -m "$1") \
    >"$SCRATCH/commit.log" 2>&1
}

# 1. A harmless change commits, and the lint really ran.
echo "linked-worktree commit check" >>"$WT/README.md"
git -C "$WT" add README.md
before="$(git -C "$WT" rev-parse HEAD)"
if ! commit "harmless change"; then
  cat "$SCRATCH/commit.log" >&2
  fail "a linked worktree that never entered its dev shell could not commit a harmless change"
fi
[ "$(git -C "$WT" rev-parse HEAD)" != "$before" ] || fail "the commit reported success but HEAD did not move"
grep -Eq '^just lint.*Passed' "$SCRATCH/commit.log" ||
  { cat "$SCRATCH/commit.log" >&2; fail "the commit did not run 'just lint'"; }

# 2. The same worktree refuses an added recording: the gate is live.
printf 'not really a recording\n' >"$WT/sample.ct"
git -C "$WT" add sample.ct
before="$(git -C "$WT" rev-parse HEAD)"
if commit "adds a recording"; then
  fail "the linked worktree committed an added *.ct recording: its hook is not a gate"
fi
grep -q 'ban added .ct recordings' "$SCRATCH/commit.log" ||
  { cat "$SCRATCH/commit.log" >&2; fail "the recording was refused, but not by ban-added-ct-recordings"; }
[ "$(git -C "$WT" rev-parse HEAD)" = "$before" ] || fail "HEAD moved although the commit was refused"
git -C "$WT" rm -q --cached sample.ct
rm -f "$WT/sample.ct"

# 3. The same worktree refuses a change `just lint` rejects. (1) only shows a
#    hook named "just lint" reported Passed; a lint script that skipped
#    itself for want of tools would report that too. An added `prek.toml` is
#    refused by scripts/check_repo_requirements.sh, so a refusal here means
#    the lint really ran, with the dev shell's tools, in a worktree whose dev
#    shell was never entered.
printf '[[repos]]\nrepo = "local"\n' >"$WT/prek.toml"
git -C "$WT" add prek.toml
before="$(git -C "$WT" rev-parse HEAD)"
if commit "adds a prek.toml"; then
  fail "the linked worktree committed a change 'just lint' rejects: its lint did not run"
fi
grep -q 'prek.toml must not exist' "$SCRATCH/commit.log" ||
  { cat "$SCRATCH/commit.log" >&2; fail "the change was refused, but not by 'just lint'"; }
[ "$(git -C "$WT" rev-parse HEAD)" = "$before" ] || fail "HEAD moved although the commit was refused"

echo "PASS: a linked worktree commits on its content without entering its dev shell, and its hook refuses an added recording and a change the lint rejects"
