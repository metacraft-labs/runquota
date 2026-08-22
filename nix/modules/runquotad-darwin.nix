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
  endpointDir = hostState.endpointDirectories.darwin;
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
      description = ''
        The group owning the host-wide state directory AND the rendezvous
        directory. Membership in it is the admission control for "may you
        participate in the managed-resource system on this host": the
        rendezvous directory is `${hostState.endpointDirectoryMode}` and
        the socket is `${hostState.endpointSocketMode}`, so a non-member is
        refused by the KERNEL rather than by anything the daemon runs.

        Defaults to `wheel` for the same reason `user` defaults to `root`
        — nix-darwin has no system-group abstraction comparable to
        NixOS's. A host that wants a real admission list should create a
        `${hostState.group}` group with `dscl` and set this to it;
        leaving it at `wheel` makes the admission list "the
        administrators", which is a decision rather than a default worth
        inheriting silently.
      '';
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
    #
    # THE RENDEZVOUS DIRECTORY IS PROVISIONED HERE TOO, and for a sharper
    # reason: its GROUP is the admission list for the whole
    # managed-resource system. A directory created by whichever process
    # started first carries whatever group that process had -- either
    # nobody, so the daemon is unreachable, or the wrong population, so
    # anyone may participate.
    #
    # `/var/run` is cleared on boot on macOS, so this rule has to run at
    # every activation AND the directory has to be re-created after a
    # reboot. `launchd.daemons` below runs as root and `RunAtLoad` fires
    # after activation on a booted system; on a fresh boot the daemon's
    # own refusal names the provisioning command.
    system.activationScripts.runquotadStateDir.text = ''
      printf 'provisioning RunQuota host-wide state directory %s\n' '${stateDir}'
      /usr/bin/install -d -m ${hostState.mode} \
        -o '${cfg.user}' -g '${cfg.group}' '${stateDir}'
      printf 'provisioning RunQuota rendezvous directory %s\n' '${endpointDir}'
      /usr/bin/install -d -m ${hostState.endpointDirectoryMode} \
        -o '${cfg.user}' -g '${cfg.group}' '${endpointDir}'
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
