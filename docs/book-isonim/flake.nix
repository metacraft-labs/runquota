# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0

{
  description = "RunQuota book — self-contained dev shell for the isonim-docs documentation site";

  inputs = {
    # `agents` carries `isonim/content/*`, which isonim-docs `dev` imports and
    # isonim `dev` lacks. Return this to `dev` once isonim promotes `agents`.
    isonim.url = "github:metacraft-labs/isonim/agents";

    isonim-docs.url = "github:metacraft-labs/isonim-docs/dev";
    isonim-docs.inputs.isonim.follows = "isonim";

    nim-everywhere = {
      url = "github:metacraft-labs/nim-everywhere/dev";
      flake = false;
    };
    nim-faststreams = {
      url = "github:metacraft-labs/nim-faststreams";
      flake = false;
    };
    nim-stew = {
      # Upstream stew removed `readPragma` in
      # https://github.com/status-im/nim-stew/commit/eeff9f5 ("Drop deprecated
      # APIs"), which the vendored serialization and chronicles still call. The
      # Metacraft fork's `codetracer` branch keeps it.
      url = "github:metacraft-labs/nim-stew/codetracer";
      flake = false;
    };

    codetracer-design-system = {
      url = "github:metacraft-labs/codetracer-design-system";
      flake = false;
    };
  };

  outputs =
    {
      self,
      isonim,
      isonim-docs,
      nim-everywhere,
      nim-faststreams,
      nim-stew,
      codetracer-design-system,
    }:
    let
      inherit (isonim.inputs) flake-utils nixpkgs;
    in
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };
      in
      {
        devShells.default = pkgs.mkShell {
          inputsFrom = [ isonim.devShells.${system}.default ];
          packages = pkgs.lib.optionals pkgs.stdenv.isLinux [ pkgs.pcre.dev ];

          shellHook = ''
            export RUNQUOTA_DOCS_ISONIM_SRC="${isonim}/src"
            export RUNQUOTA_DOCS_ISONIM_DOCS_SRC="${isonim-docs}/src"
            export RUNQUOTA_DOCS_NIM_EVERYWHERE_SRC="${nim-everywhere}/src"
            export RUNQUOTA_DOCS_NIM_FASTSTREAMS="${nim-faststreams}"
            export RUNQUOTA_DOCS_NIM_STEW="${nim-stew}"
            export RUNQUOTA_DOCS_ISONIM_VENDOR="${isonim}/vendor"
            export RUNQUOTA_DOCS_DESIGN_SYSTEM="${codetracer-design-system}"
            echo "RunQuota book dev shell — isonim-docs framework from Nix store"
          '';
        };
      }
    );
}
