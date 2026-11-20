#!/usr/bin/env bash
#
# The Nix modules' host budget file (`nix/host-config.nix`), held to its
# committed rendering and its refusals: `nix/tests/render-host-config.nix`,
# evaluated with nixpkgs' `lib` alone, must report nothing unexpected.
#
# This is the Nix half of a gate whose other half is
# `libs/runquota_daemon/tests/t_host_config_nix_module_covers_reader.nim`.
# That test holds `nix/tests/host-config-full.toml` to the daemon's reader;
# this one refuses a module that does not render that file. Without it a
# reader key could be added with the file edited by hand and no module option.
#
# `lib` comes from the nixpkgs the flake pins (read from `flake.lock`, so a
# dev shell already has it in the store), or from RUNQUOTA_NIXPKGS_LIB, a
# path to a nixpkgs `lib` directory, where that cannot be fetched.
#
# NO NIX IS NOT A PASS. A host without `nix-instantiate` (a Windows
# checkout) cannot evaluate the modules at all; the script says so and
# exits 0 only there, because nothing on that host consumes them either.
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v nix-instantiate >/dev/null 2>&1; then
  echo "check_nix_host_config: NOT RUN, nix-instantiate is not on PATH"
  exit 0
fi

if [[ -n ${RUNQUOTA_NIXPKGS_LIB:-} ]]; then
  lib_expr="import ${RUNQUOTA_NIXPKGS_LIB}"
else
  # The node the root's `nixpkgs` input resolves to: a name, or a path of
  # input names walked from the root (`follows`).
  lib_expr='
    let
      lock = builtins.fromJSON (builtins.readFile ./flake.lock);
      resolve =
        ref:
        if builtins.isString ref then
          ref
        else
          builtins.foldl'"'"' (node: name: resolve lock.nodes.${node}.inputs.${name}) lock.root ref;
      locked = lock.nodes.${resolve lock.nodes.${lock.root}.inputs.nixpkgs}.locked;
    in
    import ((builtins.fetchTarball {
      url = "https://github.com/${locked.owner}/${locked.repo}/archive/${locked.rev}.tar.gz";
      sha256 = locked.narHash;
    }) + "/lib")'
fi

unexpected=$(nix-instantiate --eval --strict --json \
  nix/tests/render-host-config.nix --arg lib "$lib_expr" -A unexpected)

if [[ $unexpected != '[]' ]]; then
  echo "FAIL: nix/host-config.nix: unexpected result for $unexpected" >&2
  echo "  (see nix/tests/render-host-config.nix; \`full\` means the rendering" >&2
  echo "  of nix/tests/host-config-full.nix differs from host-config-full.toml)" >&2
  exit 1
fi
echo "nix host-config module check passed"
