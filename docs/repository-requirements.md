# Repository Requirements

RunQuota implements the Metacraft repository requirements locally through:

- `flake.nix` for dev shells, default package output, Nix checks, and
  pre-commit hook configuration through `git-hooks.nix`.
- `.envrc` using the repository flake.
- `Justfile` targets for build, test, lint, format, version bumping,
  benchmarking, repomix snapshots, and static helper checks.
- `scripts/check_repo_requirements.sh` for the repository policy gate.
- `scripts/check_static_helpers.sh` for the ARC/staticlib and no-`ref` helper
  library gate.
- `.github/workflows/ci.yml` for parallel lint, test, and Nix build jobs with
  preserved logs, plus the `windows-compile-gate` job: runquota's tests are
  POSIX-only by construction, so the Windows leg builds every entrypoint,
  type-checks every library, smoke-runs the binaries it produced and runs the
  platform-neutral subset listed in `tests/windows/portable_tests.txt` rather
  than pretending to run the suite. Its Linux-side counterpart is
  `tests/unit/t_windows_compile_gate.nim`, which cross-checks the same
  manifests with `nim check --os:windows`.
- `.github/actionlint.yaml` declaring the self-hosted runner pools, so
  actionlint's runner-label check stays enabled rather than being drowned in
  unknown-label reports.
- `AGENTS.md` as the canonical agent instruction file, with per-tool symlinks.

Workspace source dependencies must be selected by workspace locks. This
repository must not commit `.github/sibling-pins`,
`.github/sibling-pins.json`, `.github/rr-backend-pin.txt`, or a host
workspace bootstrap config (`.repro-workspace.toml`, or the retired
`.repo-workspaces.env`) — those belong to the workspace root repo, not to a
member repo. It MAY commit `.github/sibling-repos` — that file is
the blessed clone-list declaring which sibling repos CI needs (one repo name
per line; it does not pin revisions). The shared `setup-dev-env` action clones
each listed sibling at the workspace-lock-pinned revision.
