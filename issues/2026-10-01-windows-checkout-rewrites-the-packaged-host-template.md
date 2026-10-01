# Windows checkout rewrites the packaged host configuration template

|             |                                                           |
| ----------- | --------------------------------------------------------- |
| Status      | in progress on `agents-to-dev-2026-10-01`                  |
| Recorded    | 2026-10-01                                                |
| Observed in | RunQuota `c4bfffa0cb007db75fd111e2346f24cebaea8de3`           |
| Area        | Git checkout attributes for `packaging/etc/runquotad.toml` |

## Observed

The Windows compile gate in promotion PR 36 builds the applications and passes
the other packaging checks, but fails the new template contract:

```text
packaged == HostConfigTemplate
packaging/etc/runquotad.toml differs from HostConfigTemplate in
runquota_daemon/host_config; regenerate it from the constant
```

[Failed job at c4bfffa](https://github.com/metacraft-labs/runquota/actions/runs/36886114787/job/110449719675).
The compiler is checksum-pinned Nim 2.2.8 with LLVM-MinGW 20260922, x64.
The repository has no `.gitattributes`. A real local Git checkout of the same
index with `core.autocrlf=true` changes the template's 17 LF endings to CRLF.
The resulting file differs from the source blob only by those added carriage
returns. The existing macOS contract passes against the source checkout.

## Expected

[Database documentation, The host budget file](../docs/database.md#the-host-budget-file)
requires the packaged seed to equal the daemon's `HostConfigTemplate` byte for
byte. Git checkout must preserve the canonical template bytes on Windows as
well as POSIX. Keep the test's exact-byte assertion.

## Suggested direction

Declare `text eol=lf` for this specific packaged template in `.gitattributes`.
Verify a real checkout with `core.autocrlf=true`, retaining a control without
the attribute that reproduces the mismatch. Do not normalize the comparison
or convert the daemon's canonical template at runtime.

## Local repair evidence

At `57ce33c`, the existing packaging-contract program was compiled from a real
`git -c core.autocrlf=true checkout-index --all` export. It reproduced the
Windows exact-byte failure on macOS ARM64 with pinned Nim 2.2.4.
Adding only `/packaging/etc/runquotad.toml text eol=lf` in `.gitattributes` and
checking out that file again produced zero CRLF endings and exact source-blob
bytes. The **same compiled test binary**, with every assertion unchanged,
then passed all eight packaging checks. Windows CI confirmation remains pending.

## Search

Fetched `agents` and `dev` before filing; their tips were `c4bfffa` and
`0389129`. Searched open and archived issues for `HostConfigTemplate` and
`CRLF`. The earlier service-argument parser correction at `c39e7df` handles
line endings while reading source text; it does not preserve this packaged
asset's byte contract.
