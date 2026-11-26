# nix-darwin module: `runquotad` as a launchd daemon, with its account and
# its host-wide directories provisioned by the module.
#
# Exposed as `darwinModules.runquotad` (and `.default`) from the flake.
#
# THE POINT OF THIS FILE IS THE DIRECTORIES AND THEIR OWNER, not the launchd
# job. On macOS the state directory is `/var/db/runquota` and the rendezvous
# directory `/var/run/runquota`; both parents are `root:wheel`, so an
# unprivileged daemon cannot create them, and a directory owned by anyone
# but the `runquota` account is refused by every client. The module
# therefore creates that account, and its launchd job creates both
# directories as root at every start before it drops to the account.
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
      default = hostState.user;
      description = ''
        The account `runquotad` runs as, and the OWNER of the host-wide
        state directory and the rendezvous directory. A client accepts the
        rendezvous directory only when its owner is
        `RUNQUOTA_ENDPOINT_OWNER_UID`, else the `${hostState.user}` account,
        else the client itself, so the default is that account: with it the
        daemon is accepted by every client with no environment set.

        While this keeps its default the module creates the account (see
        `uid`); a host that names another account provisions it itself.
      '';
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = hostState.group;
      description = ''
        The group owning the host-wide state directory AND the rendezvous
        directory. Membership in it is the admission list for "may you
        participate in the managed-resource system on this host": the
        rendezvous directory is `${hostState.endpointDirectoryMode}` and
        the socket is `${hostState.endpointSocketMode}`, so a non-member is
        refused by the KERNEL rather than by anything the daemon runs.

        While this keeps its default the module creates the group (see
        `gid`) and fills it from `members`.
      '';
    };

    uid = lib.mkOption {
      type = lib.types.int;
      default = 390;
      description = ''
        The uid of the `${hostState.user}` account the module creates.
        nix-darwin creates an account only with an explicit id. 390 is free
        on the Macs this default was chosen against: Apple's accounts are
        below 300 or users from 501, and Nix's build users take 301-332
        (older installs) or 351-382. Set it on a host where 390 is taken.
      '';
    };

    gid = lib.mkOption {
      type = lib.types.int;
      default = 502;
      description = ''
        The gid of the `${hostState.group}` group the module creates. Set
        it on a host where 502 is taken by another group.
      '';
    };

    members = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "alice" ];
      description = ''
        The accounts allowed to use RunQuota on this host: they become the
        members of the `${hostState.group}` group, which the rendezvous
        directory and socket admit. An account that is not listed gets no
        lease. Ignored when `group` is not the default; add members to that
        group yourself.
      '';
    };

    observationDb = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/var/db/runquota/observations.sqlite";
      description = ''
        Path to the observation store, used once capture is on. Capture is
        off by default (it costs more than the measurement budget allows);
        naming a store does not turn it on. Add
        `extraArgs = [ "--measurement" "capture=on" ]` to record; see
        `docs/database.md`.
      '';
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional arguments passed to `runquotad`.";
    };

    hostConfig = lib.mkOption {
      type = lib.types.nullOr hostConfigLib.optionType;
      default = null;
      example = lib.literalExpression ''
        { memoryBytes = 25769803776; pools = { compile = 4; }; }
      '';
      description = ''
        The host budget, written declaratively to `${hostConfigLib.path}`.
        Every key is optional; an absent one keeps the daemon's built-in
        default (75% of physical memory, one core per logical processor).
        Activation asks the running daemon to reload it
        (`runquota config reload`) rather than restarting it.

        Every table of the file has options here: `memoryBytes`, `cpuMilli`,
        `writeBytesPerSec` and `pools`, then `admission`, `benchmark`,
        `enforcement` and `reservations.<class>`. With `hostConfig` set the
        file is a store link that `runquota config set` refuses to edit, so
        these options are the only way to set a key. A value the daemon's
        reader would refuse fails the evaluation instead, except a
        reservation judged against a budget this configuration does not
        declare (the built-in default, or a budget flag in `extraArgs`):
        the daemon refuses that file at reload.

        `null` (the default) writes no file and leaves `/etc/runquota` for
        `runquota config set` to write into, as root.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # What the daemon's reader would refuse across keys, refused here.
    assertions = lib.optionals (cfg.hostConfig != null) (
      map (problem: {
        assertion = false;
        message = "services.runquotad.${problem}";
      }) (
        hostConfigLib.problems {
          budgetFromFlags = lib.any (
            arg: lib.any (flag: arg == flag || lib.hasPrefix "${flag}=" arg) hostConfigLib.budgetFlags
          ) cfg.extraArgs;
        } cfg.hostConfig
      )
    );

    # THE ACCOUNT. A client accepts the rendezvous directory only when its
    # owner is RUNQUOTA_ENDPOINT_OWNER_UID, else the `runquota` account,
    # else the client itself (`rendezvousPolicy` in libs/runquota_ipc). With
    # no `runquota` account every client expected to own the directory
    # itself, so a daemon run as anyone else was refused by all of them.
    # nix-darwin creates an account only when it is listed in `knownUsers`
    # / `knownGroups` and carries an explicit id, hence `uid` and `gid`.
    users.users = lib.mkIf (cfg.user == hostState.user) {
      ${hostState.user} = {
        uid = cfg.uid;
        gid = cfg.gid;
        home = "/var/empty";
        shell = "/usr/bin/false";
        isHidden = true;
        description = "RunQuota host-wide lease authority";
      };
    };
    users.groups = lib.mkIf (cfg.group == hostState.group) {
      ${hostState.group} = {
        gid = cfg.gid;
        members = cfg.members;
        description = "RunQuota admission list";
      };
    };
    users.knownUsers = lib.optional (cfg.user == hostState.user) hostState.user;
    users.knownGroups = lib.optional (cfg.group == hostState.group) hostState.group;

    # ACTIVATION. nix-darwin assembles its activate script from a FIXED list
    # of script names (modules/system/activation-scripts.nix); a script under
    # any other name is evaluated and never run, which is what happened to
    # this module's old `runquotadStateDir`. `postActivation` is in the list
    # and runs last, after `users` and `launchd`. `/etc/runquota` is root's
    # and is created here too, for `runquota config set`, which never creates
    # it. The two daemon-owned directories are the launchd job's (below):
    # /var/run is emptied at every boot, and activation does not run at boot.
    system.activationScripts.postActivation.text = ''
      printf 'provisioning RunQuota host configuration directory %s\n' /etc/runquota
      /usr/bin/install -d -m 0755 -o root -g wheel /etc/runquota
    ''
    + lib.optionalString (cfg.hostConfig != null) ''
      # A changed budget is a RELOAD, never a restart: the running daemon
      # keeps every session and lease. No daemon answering is not an error.
      RUNQUOTA_SOCKET='${endpointDir}/${hostState.endpointSocketName}' \
        '${cfg.package}/bin/runquota' config reload || true
    '';

    # A LINK INTO THE STORE, on purpose: `runquota config set` refuses a
    # symbolic link, so an operator is told to change the module rather than
    # having an edit undone by the next activation.
    environment.etc = lib.mkIf (cfg.hostConfig != null) {
      ${hostConfigLib.etcName}.text = hostConfigLib.render cfg.hostConfig;
    };

    # THE JOB RUNS AS ROOT AND THE DAEMON DOES NOT. A job with `UserName`
    # drops privileges before its script runs, so it could not create
    # /var/run/runquota (root's /var/run, emptied at every boot). So the
    # script provisions first, as root, at every start: `install -d` creates
    # each directory or corrects the owner and mode of one that exists
    # (a root-owned leftover included). Then it replaces itself with the
    # daemon as the daemon's account through coreutils `chroot --userspec`:
    # changing a root process's root to `/` changes nothing, and coreutils
    # then sets the supplementary groups, the gid and the uid, in that
    # order, and execs (src/chroot.c). No sudo, so the job does not depend
    # on the host's sudoers.
    launchd.daemons.runquotad = {
      script = ''
        /usr/bin/install -d -m ${hostState.mode} \
          -o '${cfg.user}' -g '${cfg.group}' '${stateDir}'
        /usr/bin/install -d -m ${hostState.endpointDirectoryMode} \
          -o '${cfg.user}' -g '${cfg.group}' '${endpointDir}'
        /usr/bin/install -d -m 0755 -o root -g wheel /etc/runquota
        exec ${pkgs.coreutils}/bin/chroot --userspec='${cfg.user}:${cfg.group}' / ${
          lib.escapeShellArgs (
            [ "${cfg.package}/bin/runquotad" ]
            ++ lib.optionals (cfg.observationDb != null) [
              "--observation-db"
              cfg.observationDb
            ]
            ++ cfg.extraArgs
          )
        }
      '';
      serviceConfig = {
        Label = "org.metacraft-labs.runquotad";
        RunAtLoad = true;
        KeepAlive = true;
      };
    };
  };
}
