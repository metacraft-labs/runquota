# Repository Requirements

RunQuota implements the Metacraft repository requirements locally through:

- `flake.nix` for dev shells, default package output, Nix checks, and
  pre-commit hook configuration through `git-hooks.nix`.
- `prek.toml`, the same pre-commit hook (`just lint`) for prek, which the
  reprobuild dev shell provides on every platform. It is how the hook runs on
  Windows, where nothing generates git-hooks.nix's `.pre-commit-config.yaml`:
  `repro exec -- prek install` once, then commit from `repro shell`.
  `scripts/check_repo_requirements.sh` requires both definitions to run
  `just lint`.
- `repro.nim`'s `uses:` for the reprobuild dev shell's tools, including the
  flake shell's lint and formatting tools (`shellcheck`, `shfmt`, `typos`,
  `prek`, `repomix`; `nixfmt` on Linux and macOS only). On Windows, where
  nobody publishes a repomix binary, `repomix` is upstream's npm package with
  its pinned dependency closure, run by the declared `node`. `just format`
  reports that it left `flake.nix` unformatted on Windows: nixfmt has no
  Windows realization yet, for reasons recorded with its interface in
  reprobuild-packages.
- `.envrc` using the repository flake.
- `Justfile` targets for build, test, lint, format, version bumping,
  benchmarking, repomix snapshots, and static helper checks.
- `scripts/check_repo_requirements.sh` for the repository policy gate.
- `scripts/check_static_helpers.sh` for the ARC/staticlib and no-`ref` helper
  library gate, which `just test` and `just check-static-helpers` reach
  through `scripts/static_helper_gate.sh`. The gate runs under one of two
  AUTHORITIES -- the thing that says which compiler and which source it ran:

  | | Nix dev shell (`nix develop`; also `repro exec` on Linux/macOS, which uses the flake's shell) | reprobuild dev shell on Windows (`repro exec -- just test`) |
  |---|---|---|
  | Entry | `runquota-static-helper-gate` (flake.nix `staticHelperGate`) | `scripts/static_helper_gate_toolstore.sh` |
  | Compiler | the `/nix/store` Nim baked into the wrapper | the dev shell's Nim, accepted only if its tool-store receipt carries the identity in `scripts/static_helper_gate_toolstore.pins`; the release archive is hashed against that pin and the compiler run is a fresh extraction of it |
  | C compiler, shell tools | store clang and coreutils on a fixed PATH | the dev shell's gcc and its Git-for-Windows bash/coreutils/git, each pinned the same way |
  | Source | the flake's `/nix/store` copy, checked for writable paths | a `git archive` of the tracked tree (index plus work-tree edits, which is what the flake copies), whose git tree id is re-verified before and after every check |
  | Checks | ARC staticlib build of every `libs/static_helpers.txt` library; `ref` scan of each one's compiler-reported closure by a scanner built from the pinned compiler's own lexer; the scanner's regression suite | the same, in `scripts/static_helper_gate_toolstore.nim`, with Windows semantics where the Nix suite asks POSIX (owner-only DACLs for `0700`, deny-read ACEs for `chmod 000`, native symbolic links) |

  Neither arm skips a check. A shell that has neither authority -- a plain
  Git Bash, a Windows PATH toolchain, or a tool-store toolchain whose
  identity is not the pinned one -- FAILS the gate, naming what went
  unchecked or which pin to change. The Windows arm's symbolic-link cases need
  `SeCreateSymbolicLinkPrivilege` (an elevated shell or Developer Mode) and
  fail by name without it. Its C compiler is gcc where the Nix arm's is
  clang: what is checked is Nim's ARC static-library code generation, not the
  C compiler that assembles it.
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
