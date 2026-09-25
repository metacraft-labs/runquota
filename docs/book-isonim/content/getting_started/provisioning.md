---
title: Provisioning a host
order: 2
---
# Provisioning a host

RunQuota uses two host-wide directories, and **it creates neither of them**.
They are made once, by an install step, before the daemon first runs. If you
have just installed RunQuota and something is refusing to work, this page is
almost certainly why.

| Directory | Linux | macOS | Windows |
|---|---|---|---|
| **Host state** — the host id and the observation store | `/var/lib/runquota` | `/var/db/runquota` | `C:\ProgramData\runquota` |
| **Rendezvous** — the socket the daemon listens on | `/run/runquota` | `/var/run/runquota` | *(none — named pipes)* |

Host state is mode `0755`. The rendezvous directory is `0750`, group
`runquota`, and the socket inside it is `0660`. On Windows there are no modes:
the host state directory must be owned by the daemon's account, SYSTEM or
Administrators, and its DACL must not let anyone else write in it (see
"Provisioning by hand" below).

## Why the daemon will not just create them

Because *a path any caller can create is a path any caller can create
**differently***. Whoever started the daemon first would decide the owner and
the mode of a directory that every user on the host has to trust, and the
difference between a rendezvous point you own and one somebody else owns is
the difference between a socket you can trust and one you cannot.

The `runquota` **group is also the admission boundary**: membership in it is
what the kernel admits a client by. Adding a user to that group is how an
operator says "you may participate in the managed-resource system on this
host". That is a decision an install step makes, not a side effect of a daemon
opening a file.

## Two directories, two very different failures

This distinction is worth internalising, because the symptoms look unrelated:

- **Rendezvous directory missing or untrustworthy → the daemon refuses to
  start**, and exits with status **3**. There is nowhere to listen; there is
  nothing useful to do.
- **Host state directory missing or untrustworthy → the daemon starts and
  serves leases normally**, and only *capture* turns off. Admission is the
  mission; refusing to admit anything because a statistics directory was
  missing would let an advisory subsystem take out the machine's entire build
  capacity.

So a host that was never provisioned at all fails loudly. A host where only
the state directory is missing keeps working, and the only sign is that
`runquota stats` has nothing to tell you — which is exactly why those commands
report *why* they are empty rather than just being empty.

## The refusals, verbatim

Missing rendezvous directory — the daemon prints this and exits 3:

```text
runquota endpoint directory /run/runquota: does not exist. It is created by
the RunQuota install step, never by the daemon; provision it with: sudo mkdir
-p /run/runquota && sudo chown <uid>:runquota /run/runquota && sudo chmod 0750
/run/runquota
```

Missing host state directory — the daemon keeps running and says this on its
third startup line:

```text
runquota host identity /var/lib/runquota/host-id: cannot persist -- the
host-wide state directory /var/lib/runquota does not exist. It is created by
the RunQuota install step, never by the daemon; provision it with: sudo mkdir
-p /var/lib/runquota && sudo chown <uid> /var/lib/runquota && sudo chmod 0755
/var/lib/runquota -- no identity was minted and capture stays off
```

Both messages carry the command with **the daemon's own uid already
substituted**, so an operator who hits one does not have to come back here to
work out what to type.

## Provisioning by hand

Run these as (or on behalf of) the account `runquotad` will run as:

```sh
# Linux
sudo mkdir -p /var/lib/runquota && sudo chown "$(id -u)" /var/lib/runquota && sudo chmod 0755 /var/lib/runquota
sudo mkdir -p /run/runquota     && sudo chown "$(id -u)":runquota /run/runquota && sudo chmod 0750 /run/runquota

# macOS
sudo mkdir -p /var/db/runquota  && sudo chown "$(id -u)" /var/db/runquota  && sudo chmod 0755 /var/db/runquota
sudo mkdir -p /var/run/runquota && sudo chown "$(id -u)":runquota /var/run/runquota && sudo chmod 0750 /var/run/runquota
```

On Windows, from an elevated `cmd.exe` (the shipped service runs as SYSTEM,
which the first two grants cover):

```bat
mkdir "C:\ProgramData\runquota" && icacls "C:\ProgramData\runquota" /reset && icacls "C:\ProgramData\runquota" /inheritance:r /grant:r "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" "%USERDOMAIN%\%USERNAME%:(OI)(CI)F" "*S-1-5-32-545:(OI)(CI)RX"
```

**A bare `mkdir` is not enough on Windows.** `C:\ProgramData` lets every user
create files in every directory made under it, so the daemon refuses such a
directory -- naming the ACE that lets other users write -- and keeps serving
leases with capture off. `/inheritance:r` is what removes that ACE. The MSI
does not create this directory.

**`/run` is cleared on boot** (and so is `/var/run` on macOS), so the
rendezvous directory has to be re-created on every boot. That is what the
systemd/launchd integration below is for; if you are provisioning by hand, put
it somewhere that runs at startup.

## Granting a user access

```sh
sudo usermod -aG runquota alice                       # Linux
sudo dseditgroup -o edit -a alice -t user runquota    # macOS
```

If the host has no `runquota` group at all, the daemon does not fail — it
degrades **visibly** to single-user mode, tightening the directory to `0700`
and the socket to `0600` and saying so on its first startup line:

```text
(single-user mode: no group "runquota" on this host, so the endpoint is
owner-only -- directory 0700, socket 0600; create the group and restart to
serve every member of it)
```

That is a working daemon that serves exactly one user. It is a reasonable
state for a laptop and the wrong state for a shared builder.

## Under Nix

RunQuota ships modules that do all of the above, including the
boot-time re-creation of the rendezvous directory:

```nix
# NixOS
services.runquotad.enable = true;
```

The NixOS module runs the daemon as user and group `runquota` with
`StateDirectory=runquota` (mode `0755`), `RuntimeDirectory=runquota` (mode
`0750`, preserved across restarts), `UMask=0007` and `Restart=on-failure`, and
adds `tmpfiles` rules so the directories survive a reboot. Options are
`package`, `user`, `group`, `observationDb` and `extraArgs`.

The nix-darwin module installs a `launchd` daemon labelled
`org.metacraft-labs.runquotad` with `RunAtLoad` and `KeepAlive`, and an
activation script that creates both directories. Note that it defaults to
running as **`root`:`wheel`** rather than a dedicated account — nix-darwin has
no system-user abstraction to hang one on.

The machine-readable copy of every path, mode, user and group on this page is
`nix/host-state.nix` in the RunQuota repository, and a test asserts that the
source code and that file agree.
