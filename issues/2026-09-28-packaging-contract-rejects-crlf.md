# Packaging contract rejects Windows source line endings

- Status: open
- Observed in: `687df21c093b2039003538732661d754fd29a3f1`

The Windows native gate builds and type-checks every entrypoint and library
and passes the binary smoke checks, then fails the empty service-argument
assertion in `t_packaging_contract.nim`. The source has `execArgs: @[],` as
required; the assertion includes the carriage return before the newline.

The service contract requires empty arguments on every platform. Strip the
line boundary whitespace before the exact comparison, keeping the complete
argument-list assertion. The native test must accept both LF and CRLF files.

Evidence: [Windows gate at 687df21](https://github.com/metacraft-labs/runquota/actions/runs/36427999623/job/108946643806).
Searched current and archived issues after refreshing dev and agents; no
earlier issue records this line-ending failure.
