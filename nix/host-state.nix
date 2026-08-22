# The host-wide, daemon-owned state directory that `runquotad` keeps this
# machine's `host_id` in.
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

  # The system user `runquotad` runs as under the modules in `nix/modules`.
  user = "runquota";
  group = "runquota";
}
