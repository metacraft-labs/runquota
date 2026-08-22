# NixOS module: `runquotad` as a system service, with its host-wide state
# directory provisioned by the install step.
#
# Exposed as `nixosModules.runquotad` (and `.default`) from the flake.
#
# THE POINT OF THIS FILE IS THE DIRECTORY, not the unit. `runquotad` mints
# the machine's `host_id` into `${stateDir}/host-id` on first start and
# refuses -- capture off, path named -- if that directory does not exist.
# Nothing in the daemon creates it, deliberately: see `nix/host-state.nix`.
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
  stateDir = hostState.directories.linux;
  # `StateDirectory=` names a path RELATIVE to /var/lib, so the two have to
  # agree. Deriving it rather than writing "runquota" twice keeps a change
  # to `nix/host-state.nix` from silently provisioning the wrong path.
  stateDirName = lib.removePrefix "/var/lib/" stateDir;
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
      default = hostState.user;
      description = ''
        The system user `runquotad` runs as, and the OWNER of the
        host-wide state directory. The daemon writes the machine's
        `host_id` there on first start, so a directory owned by anyone
        else leaves the host unprovisioned in practice.
      '';
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = hostState.group;
      description = "The group owning the host-wide state directory.";
    };

    observationDb = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/var/lib/runquota/observations.sqlite";
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
    users.users.${cfg.user} = lib.mkIf (cfg.user == hostState.user) {
      isSystemUser = true;
      group = cfg.group;
      description = "RunQuota lease authority";
    };
    users.groups.${cfg.group} = lib.mkIf (cfg.group == hostState.group) { };

    # THE PROVISIONING. Two mechanisms on purpose, and they are not
    # redundant:
    #
    #   * `StateDirectory=` creates and chowns the directory as part of
    #     starting the unit, which is what makes the daemon's first start
    #     succeed on a freshly-installed host;
    #   * the tmpfiles rule creates it at ACTIVATION, so the directory
    #     exists with the right owner and mode even before the unit has
    #     ever run and even if an operator runs `runquotad` by hand.
    #
    # Neither is the daemon creating it on demand, which is the thing that
    # must not happen: whichever of the two runs first, the owner and the
    # mode are the ones written down here rather than the ones whoever
    # started the daemon happened to have.
    systemd.tmpfiles.rules = [
      "d ${stateDir} ${hostState.mode} ${cfg.user} ${cfg.group} -"
    ];

    systemd.services.runquotad = {
      description = "RunQuota host-wide lease authority";
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" ];
      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        StateDirectory = stateDirName;
        StateDirectoryMode = hostState.mode;
        ExecStart = lib.escapeShellArgs (
          [ "${cfg.package}/bin/runquotad" ]
          ++ lib.optionals (cfg.observationDb != null) [
            "--observation-db"
            cfg.observationDb
          ]
          ++ cfg.extraArgs
        );
        Restart = "on-failure";
      };
    };
  };
}
