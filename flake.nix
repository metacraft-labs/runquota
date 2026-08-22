{
  description = "RunQuota development environment";

  inputs = {
    nixos-modules.url = "github:metacraft-labs/nixos-modules";
    nixpkgs.follows = "nixos-modules/nixpkgs-unstable";
    flake-parts.follows = "nixos-modules/flake-parts";
    git-hooks.follows = "nixos-modules/git-hooks-nix";
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
            pkgs.coreutils
            pkgs.findutils
            pkgs.gawk
            pkgs.gnugrep
            pkgs.gnused
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
          runquota = pkgs.stdenv.mkDerivation {
            pname = "runquota";
            inherit version;
            src = ./.;

            strictDeps = true;
            dontConfigure = true;

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
                  darwinActivation =
                    darwinEval.config.system.activationScripts.runquotadStateDir.text;
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
                  # `ExecStart` is dropped deliberately: it carries the
                  # x86_64-linux package's store path, and keeping it here
                  # would make this EVALUATION check demand a Linux BUILD.
                  # The point is the module system's output, not the
                  # binary's.
                  nixosService = builtins.toJSON (
                    removeAttrs nixosEval.config.systemd.services.runquotad.serviceConfig [
                      "ExecStart"
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
              staticHelperGate
              pkgs.just
              pkgs.nim2
              pkgs.nixfmt-rfc-style
              pkgs.repomix
              pkgs.pre-commit
              pkgs.shellcheck
              pkgs.shfmt
              pkgs.typos
            ];
            shellHook = pre-commit-check.shellHook;
          };
        };
    };
}
