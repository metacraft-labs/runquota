# The host budget file, `runquotad.toml`, for the Nix modules: the option
# type a module declares it with, and the TOML it renders.
#
# THE SAME PATH AND SHAPE AS `runquota_daemon/host_config`. The daemon reads
# `/etc/runquota/runquotad.toml` (`hostConfigPath`) with a reader that accepts
# exactly one subset of TOML -- a `schema` string, positive integers in
# `[machine]` and `[pools]` -- and refuses anything else, so what is rendered
# here is that subset and nothing more. `checks.module-eval` in `flake.nix`
# asserts the rendered text.
{ lib }:
let
  positive = lib.types.ints.positive;
in
{
  path = "/etc/runquota/runquotad.toml";

  # Relative to /etc, for `environment.etc`.
  etcName = "runquota/runquotad.toml";

  schema = "runquota.host-config.v1";

  optionType = lib.types.submodule {
    options = {
      memoryBytes = lib.mkOption {
        type = lib.types.nullOr positive;
        default = null;
        description = "`[machine] memory_bytes`: the host memory budget.";
      };
      cpuMilli = lib.mkOption {
        type = lib.types.nullOr positive;
        default = null;
        description = "`[machine] cpu_milli`: the host CPU budget; 1000 is one core.";
      };
      pools = lib.mkOption {
        type = lib.types.attrsOf positive;
        default = { };
        description = "`[pools]`: named counters, NAME = UNITS.";
      };
    };
  };

  render =
    cfg:
    lib.concatStringsSep "\n" (
      [
        "# Written by the runquotad Nix module (services.runquotad.hostConfig)."
        "# Change it there: `runquota config set` refuses a file linked into the store."
        "schema = \"runquota.host-config.v1\""
        ""
        "[machine]"
      ]
      ++ lib.optional (cfg.memoryBytes != null) "memory_bytes = ${toString cfg.memoryBytes}"
      ++ lib.optional (cfg.cpuMilli != null) "cpu_milli = ${toString cfg.cpuMilli}"
      ++ [
        ""
        "[pools]"
      ]
      ++ lib.mapAttrsToList (name: units: "${name} = ${toString units}") cfg.pools
    )
    + "\n";
}
