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

      perSystem =
        { pkgs, system, ... }:
        let
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
          runquota = pkgs.stdenv.mkDerivation {
            pname = "runquota";
            inherit version;
            src = ./.;

            strictDeps = true;
            dontConfigure = true;

            nativeBuildInputs = [
              pkgs.just
              pkgs.nim2
            ];

            buildPhase = ''
              runHook preBuild
              just build
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
                  nativeBuildInputs = [
                    pkgs.nim2
                    pkgs.stdenv.cc
                  ];
                }
                ''
                  cp -R ${./.} source
                  chmod -R u+w source
                  cd source
                  ${pkgs.bash}/bin/bash scripts/check_static_helpers.sh
                  mkdir -p $out
                '';
          };

          devShells.default = pkgs.mkShell {
            packages = [
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
