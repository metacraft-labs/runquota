# RunQuota

> Local resource lease coordinator for concurrent process trees. Manages CPU, memory, and I/O quotas to prevent host oversubscription during parallel builds, tests, and heavy daemon workloads.

📖 **Documentation: <https://metacraft-labs.github.io/runquota/>** — complete user guide, daemon configuration, CLI reference, and observation store guide.

## Installation

### Quick install

Install the latest release using the official Metacraft Labs bootstrapper:

- **POSIX Shell (Linux, macOS, WSL)**:
  ```bash
  curl -fsSL https://install-package.metacraft-labs.com/runquota/sh | sh
  ```
- **PowerShell (Windows)**:
  ```powershell
  irm https://install-package.metacraft-labs.com/runquota/pwsh | iex
  ```

### Package managers

RunQuota is published across official Metacraft package repositories:

- **Debian / Ubuntu**:
  ```bash
  sudo apt-get install -y runquota
  ```
  *(Requires `deb.metacraft-labs.com` repository keyring; see [docs](https://metacraft-labs.github.io/runquota/))*
- **Fedora / RHEL / openSUSE**:
  ```bash
  sudo dnf install -y runquota
  ```
  *(Requires `rpm.metacraft-labs.com` repository)*
- **macOS (Homebrew)**:
  ```bash
  brew tap metacraft-labs/metacraft
  brew install runquota
  ```
- **Windows (Scoop / MSI)**:
  ```powershell
  scoop bucket add metacraft https://github.com/metacraft-labs/metacraft-desktop-packages
  scoop install runquota
  ```
  *Native Windows MSI installers are also published on [GitHub Releases](https://github.com/metacraft-labs/runquota/releases).*
- **Nix**:
  ```bash
  nix profile install github:metacraft-labs/nixpkgs#runquota
  ```

Direct binary archives and release checksums are available on [GitHub Releases](https://github.com/metacraft-labs/runquota/releases).

## Quick Start

### Starting the daemon

RunQuota operates via a background coordinator daemon (`runquotad`) managing the machine's resource pools:

```bash
runquotad --config /etc/runquota/runquota.toml
```

### Acquiring a lease

Wrap resource-intensive commands to run under managed quotas:

```bash
runquota run --cores 4 --mem 8G -- ninja -C build
```

Query current machine usage and active leases:

```bash
runquota stats
```

## Documentation

- **[The RunQuota Book](https://metacraft-labs.github.io/runquota/)** (source in `docs/book-isonim/`):
  - [Getting Started & Core Concepts](https://metacraft-labs.github.io/runquota/getting_started/concepts)
  - [Provisioning a Host](https://metacraft-labs.github.io/runquota/getting_started/provisioning)
  - [Daemon Operation](https://metacraft-labs.github.io/runquota/usage_guide/daemon)
  - [CLI Reference](https://metacraft-labs.github.io/runquota/usage_guide/cli)
  - [Observation Store & Analytics](https://metacraft-labs.github.io/runquota/usage_guide/observations)
  - [Troubleshooting](https://metacraft-labs.github.io/runquota/reference/troubleshooting)
- **Implementer & Contributor Notes**:
  - [`docs/database.md`](docs/database.md) — observation store design and schema.
  - [`docs/releasing.md`](docs/releasing.md) — packaging and release procedures.
- **Developer Instructions**: See [`AGENTS.md`](AGENTS.md).

## License

MIT
