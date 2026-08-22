# Nix Support

Larger Nix expressions live here, so `flake.nix` stays a wiring file.

- `host-state.nix` — the two host-wide, daemon-owned directories, their owner,
  their group and their modes:
  - the **state** directory (`/var/db/runquota` on macOS, `/var/lib/runquota`
    on Linux, `0755`), duplicated from `hostWideStateDir` in
    `libs/runquota_observation_store/src/runquota_observation_store/identity.nim`;
  - the **rendezvous** directory (`/var/run/runquota` on macOS,
    `/run/runquota` on Linux, `0750`, group `runquota`), duplicated from
    `hostWideEndpointDir` in `libs/runquota_ipc/src/runquota_ipc.nim`.

  `tests/integration/t_host_identity_refusal.nim` asserts this file agrees with
  both. A directory provisioned somewhere the daemon does not look is an
  unprovisioned host with extra moving parts.
- `modules/runquotad-nixos.nix` — NixOS module, exposed as
  `nixosModules.runquotad`. Provisions **both** directories via
  `systemd.tmpfiles`, plus `StateDirectory=` / `RuntimeDirectory=`, then runs
  the daemon.
- `modules/runquotad-darwin.nix` — nix-darwin module, exposed as
  `darwinModules.runquotad`. Provisions **both** directories in an activation
  script, then runs the daemon under launchd.

The daemon never creates either directory itself. A path any caller can create
is a path any caller can create *differently*, so the owner, the group and the
mode are decided once, by installation. For the rendezvous directory the group
matters most: membership in `runquota` is what the kernel admits clients by, so
a directory created by whichever process started first carries either nobody
(the daemon is unreachable) or the wrong population (anyone may participate).
See `docs/database.md` §"Provisioning the host-wide state directory and the rendezvous" for the
by-hand equivalent on hosts not managed by Nix, and §"When the group does not
exist: single-user mode" for what a host without a `runquota` group gets: a
`0700`/`0600` owner-only endpoint and a daemon that says so, rather than a
`0750` one whose group nothing verified.

## What has actually been evaluated

Both modules are put through their **real** module systems by
`checks.module-eval` in `flake.nix`, which forces the darwin activation script,
the launchd `serviceConfig` values, the NixOS `systemd.tmpfiles` rules and the
unit's `serviceConfig`, and greps the resulting strings for the two directories,
their modes and the group. Run it with:

```sh
nix build .#checks.<system>.module-eval
```

`nix-darwin` is not a direct input of this flake; the check reaches it through
`inputs.nixos-modules.inputs.nix-darwin`, and a full `darwinSystem` evaluation
succeeds through that path. Neither module has been *activated* on a real host
by this repository's tests — evaluation is what is claimed here, and it is
claimed equally for both.
