{
  description = "RunQuota development environment";

  inputs = {
    nixos-modules.url = "github:metacraft-labs/devops-modules";
    nixpkgs.follows = "nixos-modules/nixpkgs-unstable";
    flake-parts.follows = "nixos-modules/flake-parts";
    git-hooks.follows = "nixos-modules/git-hooks-nix";

    # Pure package renderers used by release_metadata.nim. Pin their sources
    # independently of the operator's installed repro executable.
    release-packaging-src = {
      url = "github:metacraft-labs/reprobuild/fb9f2e764b98acdd2d0a0c3ab622f3287bc78b0a";
      flake = false;
    };
    release-nimcrypto-src = {
      url = "github:cheatfate/nimcrypto/69eec0375dd146aede41f920c702c531bfe89c6b";
      flake = false;
    };
    release-bearssl-src = {
      url = "git+https://github.com/status-im/nim-bearssl?submodules=1&rev=9a4eed052abbded2d94feaf3f5bbd95a30ec4671";
      flake = false;
    };

    # THE SHARED-MEMORY LIBRARY, and M13b is the first thing in this repo
    # that needs it. `runquota_stats_table` -- the published aggregate
    # table -- reuses `shm_lease/anchor` (boot id, process start time, the
    # pid-reuse-proof liveness verdict), `shm_lease/waitword` (the host
    # page size, which is 16 KiB on Apple Silicon and never 4096) and, in
    # the tests, `shm_lease/syscount` (the KERNEL-maintained syscall
    # counter the zero-syscall gate is measured with rather than argued
    # from).
    #
    # AN INPUT RATHER THAN A SIBLING CHECKOUT, because `packages.default`
    # builds from a pure `src = ./.` copy with no siblings in it. Wiring
    # this only through `config.nims`'s workspace fallback would have left
    # `nix build .#default` producing a `runquotad` that silently does not
    # publish -- a feature difference between the packaged daemon and the
    # developer's, which is the failure mode this whole campaign keeps
    # finding. `flake = false`: `nim-shm-lease` is a source tree, not a
    # flake.
    nim-shm-lease = {
      url = "github:metacraft-labs/nim-shm-lease";
      flake = false;
    };
  };

  outputs =
    inputs@{
      self,
      flake-parts,
      git-hooks,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      # THE INSTALL STEP. `runquotad` keeps this machine's `host_id` in a
      # host-wide, daemon-owned directory (`/var/lib/runquota` on Linux,
      # `/var/db/runquota` on macOS) and REFUSES -- capture off, path and
      # reason named -- when that directory is missing. It never creates
      # it: a path any caller can create is a path any caller can create
      # differently. These modules are what creates it, with the owner and
      # mode fixed in `nix/host-state.nix`.
      #
      # Hosts not managed by Nix provision it from the runbook in
      # `docs/database.md`, which carries the same owner and mode.
      flake = {
        nixosModules.runquotad = import ./nix/modules/runquotad-nixos.nix { inherit self; };
        nixosModules.default = self.nixosModules.runquotad;
        darwinModules.runquotad = import ./nix/modules/runquotad-darwin.nix { inherit self; };
        darwinModules.default = self.darwinModules.runquotad;
        hostState = import ./nix/host-state.nix;
      };

      perSystem =
        { pkgs, system, ... }:
        let
          hostState = import ./nix/host-state.nix;
          # THE DARWIN MODULE IS EVALUATED, NOT MERELY PARSED.
          #
          # It used to be described in `nix/README.md` and `docs/database.md`
          # exactly as the NixOS one is, while only the NixOS one had ever
          # been through a real module system -- so an operator reading
          # either document could not tell the verified module from the
          # unverified one. `nix-darwin` is not a direct input of this
          # flake, but it is reachable transitively through
          # `nixos-modules`, and a full `darwinSystem` evaluation succeeds
          # through that path. `checks.module-eval` below is that
          # evaluation, and it forces the activation script and the launchd
          # job rather than stopping at the option declarations.
          nix-darwin = inputs.nixos-modules.inputs.nix-darwin;
          darwinEval = nix-darwin.lib.darwinSystem {
            modules = [
              self.darwinModules.runquotad
              {
                nixpkgs.hostPlatform = "aarch64-darwin";
                system.stateVersion = 5;
                system.primaryUser = hostState.user;
                services.runquotad.enable = true;
                services.runquotad.hostConfig.memoryBytes = 25769803776;
              }
            ];
          };
          nixosEval = inputs.nixos-modules.inputs.nixpkgs.lib.nixosSystem {
            modules = [
              self.nixosModules.runquotad
              {
                nixpkgs.hostPlatform = "x86_64-linux";
                boot.loader.grub.devices = [ "/dev/sda" ];
                fileSystems."/" = {
                  device = "/dev/sda1";
                  fsType = "ext4";
                };
                system.stateVersion = "24.05";
                services.runquotad.enable = true;
                services.runquotad.hostConfig = {
                  memoryBytes = 103079215104;
                  cpuMilli = 16000;
                  pools.compile = 8;
                };
              }
            ];
          };
          version =
            let
              versionMatches = builtins.filter (match: match != null) (
                map (line: builtins.match ''version = "([^"]+)"'' line) (
                  pkgs.lib.splitString "\n" (builtins.readFile ./runquota.nimble)
                )
              );
            in
            builtins.elemAt (builtins.head versionMatches) 0;
          # git-hooks.nix installs `.pre-commit-config.yaml` and git hooks into
          # `git rev-parse --show-toplevel` of the directory the shell is entered
          # from, so `nix develop /path/to/<this repo>` run inside another checkout
          # would plant this repository's hooks there. `ownRepoOnly` runs a snippet
          # only when that toplevel is this repository, recognised by a `flake.nix`
          # identical to the one this shell was evaluated from; anything it cannot
          # establish counts as another repository, so it fails safe.
          # tests/test_dev_shell_writes_nothing_elsewhere.sh
          ownRepoOnly = script: ''
            _own_repo_root="$(${pkgs.git}/bin/git rev-parse --show-toplevel 2>/dev/null || true)"
            if [ -n "$_own_repo_root" ] && [ -f "$_own_repo_root/flake.nix" ] \
              && [ "$(${pkgs.coreutils}/bin/sha256sum "$_own_repo_root/flake.nix" | ${pkgs.coreutils}/bin/cut -d' ' -f1)" \
                = "${builtins.hashFile "sha256" ./flake.nix}" ]; then
            ${script}
            # git-hooks.nix's installer leaves core.hooksPath as the RELATIVE
            # `.git/hooks`, in the config every worktree shares. A linked worktree
            # cannot resolve it (there `.git` is a file), so git silently runs no
            # hooks there. Point it at the common hooks directory instead.
            if [ "$(${pkgs.git}/bin/git config --local --get core.hooksPath 2>/dev/null)" = .git/hooks ]; then
              ${pkgs.git}/bin/git config --local core.hooksPath "$(${pkgs.git}/bin/git rev-parse --path-format=absolute --git-common-dir)/hooks"
            fi
            # The installer moves each Reprobuild hook dispatcher aside to
            # `<hook>.legacy` and puts pre-commit's shim in its slot, so the managed
            # hook (for pre-push, the publication gate) runs only by accident. Put the
            # dispatcher back and chain the shim as `<hook>.repro-local`, which the
            # dispatcher runs: the layout `repro hooks ensure --vcs` produces.
            _hooks="$(${pkgs.git}/bin/git rev-parse --path-format=absolute --git-path hooks 2>/dev/null || true)"
            for _legacy in "$_hooks"/*.legacy; do
              [ -f "$_legacy" ] && grep -q 'reprobuild hook dispatcher' "$_legacy" || continue
              _slot="''${_legacy%.legacy}"
              if [ -f "$_slot" ] && grep -q 'reprobuild hook dispatcher' "$_slot"; then
                rm -f "$_legacy"
              elif [ ! -e "$_slot" ] || grep -Eq '^# File generated by (pre-commit|prek)' "$_slot"; then
                if [ -f "$_slot.repro-local" ] && ! grep -Eq '^# File generated by (pre-commit|prek)' "$_slot.repro-local"; then
                  echo "git-hooks: $_slot.repro-local is your own hook; run 'repro hooks ensure --vcs' to reconcile." >&2
                  continue
                fi
                if [ -e "$_slot" ]; then mv -f "$_slot" "$_slot.repro-local"; fi
                mv -f "$_legacy" "$_slot"
              else
                echo "git-hooks: $_slot is not a pre-commit shim; run 'repro hooks ensure --vcs' to reconcile." >&2
              fi
            done
            unset _hooks _legacy _slot
            fi
            unset _own_repo_root
          '';
          pre-commit-check = git-hooks.lib.${system}.run {
            src = ./.;
            hooks.just-lint = {
              enable = true;
              name = "just lint";
              entry = "just lint";
              language = "system";
              pass_filenames = false;
            };
          };
          staticHelperGatePath = pkgs.lib.makeBinPath [
            pkgs.bash
            pkgs.clang
            pkgs.coreutils
            pkgs.findutils
            pkgs.gawk
            pkgs.gnugrep
            pkgs.gnused
            pkgs.llvmPackages.llvm
            pkgs.nim2
            pkgs.stdenv.cc
          ];
          staticHelperGate = pkgs.writeShellScriptBin "runquota-static-helper-gate" ''
            set -euo pipefail

            gate_self="$(${pkgs.coreutils}/bin/realpath -e -- "$0")"
            if [ "$#" -eq 1 ] && [ "$1" = "--print-authority" ]; then
              printf 'nim=%s\nsource=%s\npath=%s\ngate=%s\n' \
                '${pkgs.nim2}/bin/nim' \
                '${./.}' \
                '${staticHelperGatePath}' \
                "$gate_self"
              exit 0
            fi
            if [ "$#" -ne 0 ]; then
              echo "usage: runquota-static-helper-gate [--print-authority]" >&2
              exit 2
            fi

            exec ${pkgs.coreutils}/bin/env -i \
              PATH='${staticHelperGatePath}' \
              LC_ALL=C \
              LANG=C \
              ${pkgs.bash}/bin/bash \
              '${./.}/scripts/check_static_helpers.sh' \
              '${pkgs.nim2}/bin/nim' \
              '${./.}' \
              "$gate_self"
          '';
          shmLeaseSrc = "${inputs.nim-shm-lease}/src";
          runquota = pkgs.stdenv.mkDerivation {
            pname = "runquota";
            inherit version;
            src = ./.;

            strictDeps = true;
            dontConfigure = true;

            # Read by `config.nims`. Not a convenience: without it the
            # published aggregate table does not compile, and the point of
            # setting it HERE is that the packaged daemon is built from the
            # same sources as the developer's.
            SHM_LEASE_SRC = shmLeaseSrc;

            nativeBuildInputs = [
              pkgs.bash
              pkgs.coreutils
              pkgs.just
              pkgs.nim2
            ];

            buildPhase = ''
              runHook preBuild
              mkdir -p test-logs
              ${pkgs.bash}/bin/bash scripts/build_apps.sh 2>&1 | tee test-logs/build.log
              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall
              mkdir -p "$out/bin"
              install -m755 build/bin/runquota "$out/bin/runquota"
              install -m755 build/bin/runquotad "$out/bin/runquotad"
              runHook postInstall
            '';

            meta = {
              description = "Local resource lease coordinator for concurrent process trees";
              homepage = "https://github.com/metacraft-labs/runquota";
              license = pkgs.lib.licenses.mit;
              mainProgram = "runquota";
              platforms = [
                "x86_64-linux"
                "aarch64-linux"
                "x86_64-darwin"
                "aarch64-darwin"
              ];
            };
          };
        in
        {
          packages.default = runquota;
          packages.runquota = runquota;

          checks = {
            inherit pre-commit-check;
            package-build = runquota;

            # Both install steps, put through their real module systems and
            # asserted on their OUTPUT. The strings compared here are the
            # two host-wide directories, their modes and their group -- the
            # facts the daemon refuses to start without.
            module-eval =
              pkgs.runCommand "runquota-module-eval"
                {
                  # Context discarded: with `hostConfig` set the script calls
                  # `runquota config reload` from the aarch64-darwin package,
                  # and this EVALUATION check must not demand that build.
                  darwinActivation = builtins.unsafeDiscardStringContext darwinEval.config.system.activationScripts.runquotadStateDir.text;
                  # The VALUES, not the attribute names: nix-darwin
                  # declares every launchd key whether or not it was set,
                  # so a grep over the names would pass against a module
                  # that configured nothing at all.
                  darwinLaunchd = builtins.toJSON {
                    inherit (darwinEval.config.launchd.daemons.runquotad.serviceConfig)
                      Label
                      UserName
                      GroupName
                      RunAtLoad
                      ;
                  };
                  nixosTmpfiles = builtins.toJSON nixosEval.config.systemd.tmpfiles.rules;
                  # The host budget file each module renders, which the
                  # daemon's strict reader must accept.
                  nixosHostConfig = nixosEval.config.environment.etc."runquota/runquotad.toml".text;
                  darwinHostConfig = darwinEval.config.environment.etc."runquota/runquotad.toml".text;
                  nixosReload = builtins.unsafeDiscardStringContext nixosEval.config.systemd.services.runquotad.serviceConfig.ExecReload;
                  # `ExecStart` is dropped deliberately: it carries the
                  # x86_64-linux package's store path, and keeping it here
                  # would make this EVALUATION check demand a Linux BUILD.
                  # The point is the module system's output, not the
                  # binary's.
                  nixosService = builtins.toJSON (
                    removeAttrs nixosEval.config.systemd.services.runquotad.serviceConfig [
                      "ExecStart"
                      "ExecReload"
                    ]
                  );
                }
                ''
                  printf '%s' "$darwinActivation" > darwin-activation
                  grep -F '${hostState.directories.darwin}' darwin-activation
                  grep -F '${hostState.endpointDirectories.darwin}' darwin-activation
                  grep -F '${hostState.mode}' darwin-activation
                  grep -F '${hostState.endpointDirectoryMode}' darwin-activation
                  printf '%s' "$darwinLaunchd" > darwin-launchd
                  grep -F '"GroupName":"wheel"' darwin-launchd
                  grep -F '"UserName":"root"' darwin-launchd
                  grep -F 'org.metacraft-labs.runquotad' darwin-launchd

                  printf '%s' "$nixosTmpfiles" > nixos-tmpfiles
                  grep -F '${hostState.directories.linux}' nixos-tmpfiles
                  grep -F '${hostState.endpointDirectories.linux}' nixos-tmpfiles
                  grep -F '${hostState.endpointDirectoryMode}' nixos-tmpfiles
                  grep -F '${hostState.group}' nixos-tmpfiles

                  printf '%s' "$nixosHostConfig" > nixos-host-config
                  grep -Fx 'schema = "runquota.host-config.v1"' nixos-host-config
                  grep -Fx 'memory_bytes = 103079215104' nixos-host-config
                  grep -Fx 'cpu_milli = 16000' nixos-host-config
                  grep -Fx 'compile = 8' nixos-host-config
                  grep -F 'd /etc/runquota 0755 root root -' nixos-tmpfiles
                  printf '%s' "$nixosReload" | grep -F 'runquota config reload'
                  printf '%s' "$darwinHostConfig" > darwin-host-config
                  grep -Fx 'memory_bytes = 25769803776' darwin-host-config
                  grep -F '/etc/runquota' darwin-activation

                  printf '%s' "$nixosService" > nixos-service
                  grep -F 'RuntimeDirectory' nixos-service
                  grep -F 'StateDirectory' nixos-service

                  mkdir -p $out
                '';

            repo-requirements =
              pkgs.runCommand "runquota-repo-requirements" { nativeBuildInputs = [ pkgs.just ]; }
                ''
                  cp -R ${./.} source
                  chmod -R u+w source
                  cd source
                  ${pkgs.bash}/bin/bash scripts/check_repo_requirements.sh
                  mkdir -p $out
                '';
            static-helpers =
              pkgs.runCommand "runquota-static-helpers"
                {
                  nativeBuildInputs = [ staticHelperGate ];
                }
                ''
                  mkdir -p hostile-config
                  ${pkgs.coreutils}/bin/env \
                    RUNQUOTA_PINNED_NIM=/usr/bin/false \
                    RUNQUOTA_SOURCE_ROOT="$PWD" \
                    PATH=/runquota-hostile-path \
                    HOME="$PWD/hostile-config" \
                    XDG_CONFIG_HOME="$PWD/hostile-config" \
                    XDG_CONFIG_DIRS="$PWD/hostile-config" \
                    NIMBLE_DIR="$PWD/hostile-config" \
                    NIM_LIB_PREFIX="$PWD/hostile-config" \
                    NIM_CONFIG_DIR="$PWD/hostile-config" \
                    REPROBUILD_SRC="$PWD/hostile-config" \
                    CC=/usr/bin/false \
                    CXX=/usr/bin/false \
                    ${staticHelperGate}/bin/runquota-static-helper-gate
                  mkdir -p $out
                '';
          };

          devShells.default = pkgs.mkShell {
            packages = [
              pkgs.nodejs
              staticHelperGate
              pkgs.just
              pkgs.nim2
              pkgs.nixfmt-rfc-style
              pkgs.repomix
              pkgs.pre-commit
              pkgs.shellcheck
              pkgs.shfmt
              # THE `sqlite3` TOOL, which is a RUNTIME dependency of the
              # observation store and of `runquota_persistence`: both reach
              # SQLite by spawning the command-line tool rather than by
              # linking a library, precisely so that its absence is a
              # catchable condition (OS-4, "degrade, never fail") instead of
              # a load-time abort. `findExe "sqlite3"` is the whole test.
              #
              # Its absence from this list is what made that degradation the
              # DEFAULT in CI: `nix develop --command just test` ran with no
              # tool on PATH, every store opened as
              # `degraded-no-sqlite-tool`, and roughly half the suite
              # asserted against a store that had refused to exist. A green
              # run then meant "the tool is missing", not "the store works".
              # The `bin` output is `pkgs.sqlite`'s first, so this is the
              # CLI and not just the library.
              pkgs.sqlite
              pkgs.typos
            ]
            ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
              pkgs.zig
              pkgs.patchelf
              pkgs.binutils
              pkgs.dpkg
              pkgs.rpm
              pkgs.libarchive
            ];
            SHM_LEASE_SRC = shmLeaseSrc;
            RELEASE_PACKAGING_SRC = inputs.release-packaging-src;
            RELEASE_NIMCRYPTO_SRC = inputs.release-nimcrypto-src;
            RELEASE_BEARSSL_SRC = inputs.release-bearssl-src;
            shellHook = ownRepoOnly pre-commit-check.shellHook;
          };
        };
    };
}
