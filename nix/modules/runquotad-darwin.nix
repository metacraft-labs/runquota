# nix-darwin module: `runquotad` as a launchd daemon, with its host-wide
# state directory provisioned by the install step.
#
# Exposed as `darwinModules.runquotad` (and `.default`) from the flake.
#
# THE POINT OF THIS FILE IS THE DIRECTORY, not the launchd job. On macOS
# the path is `/var/db/runquota`, and `/var/db` is `root:wheel 0755`, so an
# unprivileged daemon cannot create it. That is the whole defect M13c-fix
# repairs: nothing provisioned it, so `resolveHostIdentity()` failed and
# the old code answered by minting a fresh id on every invocation.
#
# `launchd.daemons` runs as root, so the activation script below can chown
# the directory to the account the daemon actually runs under.
{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.runquotad;
  hostState = import ../host-state.nix;
  stateDir = hostState.directories.darwin;
in
{
  options.services.runquotad = {
    enable = lib.mkEnableOption "the RunQuota host-wide lease authority";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.runquota;
      defaultText = lib.literalExpression "runquota.packages.\${system}.runquota";
      description = "The RunQuota package providing `runquotad`.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "root";
      description = ''
        The account `runquotad` runs as, and the OWNER of the host-wide
        state directory. The daemon writes the machine's `host_id` there
        on first start, so a directory owned by anyone else leaves the
        host unprovisioned in practice.

        Defaults to `root` because nix-darwin has no system-user
        abstraction comparable to NixOS's; set it to a dedicated account
        if one exists on the host.
      '';
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "wheel";
      description = "The group owning the host-wide state directory.";
    };

    observationDb = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/var/db/runquota/observations.sqlite";
      description = ''
        Path to the observation store. Capture is off unless this is set;
        see `docs/database.md`.
      '';
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional arguments passed to `runquotad`.";
    };
  };

  config = lib.mkIf cfg.enable {
    # THE PROVISIONING. It runs at activation, before any `runquotad` has
    # started, so the directory's owner and mode are the ones written down
    # in `nix/host-state.nix` rather than the ones whichever process
    # started first happened to have. `install -d` is idempotent and also
    # corrects the mode and owner of a directory that already exists,
    # which matters on a host where somebody once created it by hand.
    system.activationScripts.runquotadStateDir.text = ''
      printf 'provisioning RunQuota host-wide state directory %s\n' '${stateDir}'
      /usr/bin/install -d -m ${hostState.mode} \
        -o '${cfg.user}' -g '${cfg.group}' '${stateDir}'
    '';

    launchd.daemons.runquotad = {
      script = lib.escapeShellArgs (
        [ "${cfg.package}/bin/runquotad" ]
        ++ lib.optionals (cfg.observationDb != null) [
          "--observation-db"
          cfg.observationDb
        ]
        ++ cfg.extraArgs
      );
      serviceConfig = {
        Label = "org.metacraft-labs.runquotad";
        RunAtLoad = true;
        KeepAlive = true;
        UserName = cfg.user;
        GroupName = cfg.group;
      };
    };
  };
}
