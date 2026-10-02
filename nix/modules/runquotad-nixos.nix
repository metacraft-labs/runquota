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
  hostConfigLib = import ../host-config.nix { inherit lib; };
  stateDir = hostState.directories.linux;
  # `StateDirectory=` names a path RELATIVE to /var/lib, so the two have to
  # agree. Deriving it rather than writing "runquota" twice keeps a change
  # to `nix/host-state.nix` from silently provisioning the wrong path.
  stateDirName = lib.removePrefix "/var/lib/" stateDir;
  endpointDir = hostState.endpointDirectories.linux;
  # `RuntimeDirectory=` names a path RELATIVE to /run, so the two have to
  # agree. Derived rather than written twice.
  endpointDirName = lib.removePrefix "/run/" endpointDir;
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
      description = ''
        The group owning the host-wide state directory AND the rendezvous
        directory. Membership in it is the admission control for "may you
        participate in the managed-resource system on this host": the
        rendezvous directory is `${hostState.endpointDirectoryMode}` and
        the socket is `${hostState.endpointSocketMode}`, so a non-member
        is refused by the KERNEL rather than by anything the daemon runs.

        Add a user to this group to let them use RunQuota:
        `users.users.<name>.extraGroups = [ "${hostState.group}" ];`
      '';
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

    hostConfig = lib.mkOption {
      type = lib.types.nullOr (hostConfigLib.optionType);
      default = null;
      example = lib.literalExpression ''
        {
          memoryBytes = 103079215104; # 96 GiB
          cpuMilli = 16000;
          pools = { compile = 8; fetch = 2; };
        }
      '';
      description = ''
        The host budget, written declaratively to
        `${hostConfigLib.path}` (a link into the store). Every
        key is optional; an absent one keeps the daemon's built-in
        default: 75% of physical memory and one core per logical
        processor. A change is applied by RELOADING the running daemon
        (`runquota config reload`), not by restarting it, so switching
        configurations does not drop every build session on the host.

        `null` (the default) writes no file and leaves the directory for
        `runquota config set` to write into, as root.
      '';
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
    #
    # THE RENDEZVOUS DIRECTORY IS PROVISIONED THE SAME WAY, and for a
    # sharper reason: its GROUP is the admission list. A directory created
    # by whichever process started first carries whatever group that
    # process had, which is either nobody (the daemon is unreachable) or
    # the wrong population (anyone may participate).
    systemd.tmpfiles.rules = [
      "d ${stateDir} ${hostState.mode} ${cfg.user} ${cfg.group} -"
      "d ${endpointDir} ${hostState.endpointDirectoryMode} ${cfg.user} ${cfg.group} -"
      # THE HOST BUDGET FILE'S DIRECTORY: root-owned 0755, like the rest of
      # /etc. The daemon reads the file and never writes it; root writes it,
      # through `hostConfig` below or `runquota config set`, which never
      # creates the directory itself.
      "d /etc/runquota 0755 root root -"
    ];

    environment.etc = lib.mkIf (cfg.hostConfig != null) {
      # A LINK INTO THE STORE, on purpose (no `mode`): `runquota config set`
      # refuses a symbolic link, so an operator is told to change the module
      # rather than having an edit silently undone by the next activation.
      ${hostConfigLib.etcName}.text = hostConfigLib.render cfg.hostConfig;
    };

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
        RuntimeDirectory = endpointDirName;
        RuntimeDirectoryMode = hostState.endpointDirectoryMode;
        # The rendezvous must survive a restart of the unit; recreating it
        # on every start is the "created by whoever started first" defect
        # with extra steps.
        RuntimeDirectoryPreserve = true;
        # The daemon binds the socket at 0660 itself; this keeps a lax
        # inherited umask from being what decides it.
        UMask = "0007";
        ExecStart = lib.escapeShellArgs (
          [ "${cfg.package}/bin/runquotad" ]
          ++ lib.optionals (cfg.observationDb != null) [
            "--observation-db"
            cfg.observationDb
          ]
          ++ cfg.extraArgs
        );
        Restart = "on-failure";
        # A new budget is a RELOAD: the daemon re-reads its file and keeps
        # every session and lease (granted leases are never revoked; see
        # "Changing it under a running daemon" in the host-configuration
        # spec). A restart would drop every build on the host.
        ExecReload = "${cfg.package}/bin/runquota config reload";
      };
      environment.RUNQUOTA_SOCKET = "${endpointDir}/${hostState.endpointSocketName}";
      reloadTriggers = lib.optional (cfg.hostConfig != null) (hostConfigLib.render cfg.hostConfig);
    };
  };
}
