# Nix Support

Larger Nix expressions live here, so `flake.nix` stays a wiring file.

- `host-state.nix` — the host-wide, daemon-owned state directory
  (`/var/db/runquota` on macOS, `/var/lib/runquota` on Linux), its owner and
  its mode. **These paths are duplicated from `hostWideStateDir` in
  `libs/runquota_observation_store/src/runquota_observation_store/identity.nim`**,
  and `tests/integration/t_host_identity_refusal.nim` asserts the two agree.
  A directory provisioned somewhere the daemon does not look is an
  unprovisioned host with extra moving parts.
- `modules/runquotad-nixos.nix` — NixOS module, exposed as
  `nixosModules.runquotad`. Provisions the state directory via
  `systemd.tmpfiles` **and** `StateDirectory=`, then runs the daemon.
- `modules/runquotad-darwin.nix` — nix-darwin module, exposed as
  `darwinModules.runquotad`. Provisions the state directory in an activation
  script, then runs the daemon under launchd.

The daemon never creates that directory itself. A path any caller can create is
a path any caller can create *differently*, so its owner and mode are decided
once, by installation. See `docs/database.md` §"Provisioning the host-wide
state directory" for the by-hand equivalent on hosts not managed by Nix.
