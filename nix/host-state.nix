# The two host-wide, daemon-owned directories `runquotad` needs: the STATE
# directory it keeps this machine's `host_id` in, and the RENDEZVOUS
# directory it binds its socket in.
#
# THIS FILE IS THE INSTALL STEP'S COPY OF A PATH THE DAEMON ALSO KNOWS.
# The same three paths appear as `hostWideStateDir` in
# `libs/runquota_observation_store/src/runquota_observation_store/identity.nim`,
# and `tests/integration/t_host_identity_refusal.nim` asserts the two agree.
# A directory provisioned somewhere the daemon does not look is an
# unprovisioned host with extra moving parts.
#
# WHY AN INSTALL STEP AT ALL, rather than `mkdir -p` on first start: a path
# any caller can create is a path any caller can create DIFFERENTLY. The
# owner and the mode of a host-wide directory are decided once, by whoever
# installs the daemon, and not by whichever process happened to start
# first. `runquotad` refuses -- capture off, path and reason named -- when
# the directory is missing, rather than creating one and minting an
# identity that will not survive the process.
{
  # Platform state directories. `/var/db` is the macOS convention for
  # daemon-owned persistent state; `/var/lib` is the Linux one.
  directories = {
    linux = "/var/lib/runquota";
    darwin = "/var/db/runquota";
    windows = ''C:\ProgramData\runquota'';
  };

  # The identity file inside it.
  identityFileName = "host-id";

  # 0755, not 0700. The directory is host-wide by design: one daemon per
  # host, one identity per host. It is the DAEMON that must be able to
  # write it, so ownership is the daemon's user rather than root's --
  # a root-owned directory reproduces exactly the defect this provisioning
  # exists to fix, because the unprivileged daemon still cannot mint into
  # it.
  mode = "0755";

  # ---------------------------------------------------------------------
  # The RENDEZVOUS directory: where clients find the daemon.
  #
  # THE SAME THREE PATHS APPEAR AS `hostWideEndpointDir` in
  # `libs/runquota_ipc/src/runquota_ipc.nim`, and
  # `tests/integration/t_host_identity_refusal.nim` asserts the two agree.
  #
  # A FIXED PATH WITH NOTHING CALLER-DERIVED IN IT. This replaced
  # `<XDG_RUNTIME_DIR or TMPDIR>/runquota-$UID`, whose defect was not that
  # a second user was locked out but that a second user COMPUTED A
  # DIFFERENT PATH, found nothing, and started a daemon of their own --
  # so a host-wide daemon degraded silently to one per user, which is the
  # exact outcome the host-wide design exists to prevent.
  #
  # Provisioned by the install step for the same reason the state
  # directory is: whichever process starts first would otherwise decide
  # the owner and, worse, the GROUP -- and the group is the admission list
  # for the whole managed-resource system on this host.
  # ---------------------------------------------------------------------
  endpointDirectories = {
    linux = "/run/runquota";
    darwin = "/var/run/runquota";
    windows = ""; # Named pipes live in the kernel object namespace.
  };

  endpointSocketName = "runquotad.sock";

  # 0750, not 0700 and not 0755. Group members traverse and connect;
  # nobody but the daemon creates or replaces. Group- or other-WRITABLE is
  # the thing that must never happen, and 0750 is how that is enforced
  # alongside "the mode was verified rather than assumed".
  endpointDirectoryMode = "0750";

  # The socket: group-writable BY THE `runquota` GROUP ONLY, which is what
  # lets a member connect and leaves a non-member refused by the kernel.
  endpointSocketMode = "0660";

  # The system user `runquotad` runs as under the modules in `nix/modules`.
  #
  # `group` is ALSO the admission boundary: membership in it is what the
  # kernel admits a client by. Adding a user to this group is how an
  # operator says "you may participate in the managed-resource system on
  # this host".
  user = "runquota";
  group = "runquota";
}
