# macOS native cross-check inherits an overlong temporary root

Status: open. Observed at RunQuota `a9d9f40`.

## Observed

The full Reprobuild graph passes, then the native cross-check in macOS job
[109583410697](https://github.com/metacraft-labs/runquota/actions/runs/36620199738/job/109583410697)
fails 23 test programs. Many fail with `socket path too long`; the shutdown
fixture reports an actual path under
`/var/folders/36/tjdph2t965j8snz9_vkdnw0r0000gn/T/nix-shell.OhPi1G/`
with its fixture directory and `d.sock` appended. It exceeds Nim's
`Sockaddr_un_path_length` before the socket assertion can run. The separate
native workflow passes 487 checks at this same source revision; its actual
temporary root was not captured.

## Expected and repair

The [release validation spec](../../metacraft-specs/infrastructure/gosti-io-mon-runquota-releases.md)
requires the canonical native harness and Reprobuild graph to run the complete
fixture set. `t_shutdown_handler_lifecycle.bindListener` explicitly asserts
the OS/Nim socket-path bound; keep that assertion.

Give `scripts/run_tests.sh` a private, short temporary root on macOS and pass
it to every fixture. Keep all transport, permissions and teardown assertions.
Delete the harness-owned root on success and retain it with a diagnostic on
failure. Validate the original failure and repaired real shutdown/lease
fixtures with an intentionally long incoming `TMPDIR`, then the full suite.

Refreshed dev `e9f9011` and searched open/deleted issues for socket length and
temporary paths before filing. Full log:
`/tmp/runquota-a9-macos-repro-final.log`. The Windows image-lock issue has a
different cause and repair.

## Repair validation

At `0b6f86c` plus the harness repair, the real shutdown program passes all
five checks and the single-client lease program passes its real daemon check
with an inherited 69-character `TMPDIR`. The original harness at `9b69ba2`
fails three shutdown checks under the same-length root. ShellCheck passes;
the complete macOS native cross-check is still required.
