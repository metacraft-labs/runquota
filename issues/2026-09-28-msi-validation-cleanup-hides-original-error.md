# MSI validation cleanup hides the original failure

Status: In progress

## Expectation

The approved release specification in
`metacraft-specs/infrastructure/gosti-io-mon-runquota-releases.md`,
"Payloads and verification", requires all ICE checks, table verification,
administrative extraction, payload comparison and execution before publication.
A failed check must retain enough evidence to diagnose it.

## Observation

At `906800c15c37b2fd955532d5ded1b8b4ee9c6445`, release job
[108792401428](https://github.com/metacraft-labs/runquota/actions/runs/36377390368/job/108792401428)
passes x64 MSI ICE validation and all 20 table assertions on Windows ARM64.
The retained Windows Installer log reports successful administrative extraction
with exit 0. The script then fails in `finally` while removing the extracted
`runquota.exe` (access denied), hiding any earlier exception. ARM64 MSI validation
is not reached. This is not evidence that the complete MSI gate passed.

## Repair and remaining verification

Preserve the original exception, add stage diagnostics, retain a directly owned
process handle and exit status for Windows Installer, and retry transient cleanup
failures briefly. Run the unchanged full validation requirements again on a
native Windows ARM64 runner. Do not suppress a failed payload or ICE check.

## Repair verification, 2026-09-28

Diagnostic workflow `36425300183`, scripts at `939c38a`, verifies the previously
native-tested `e9e487a` artifacts for both Windows architectures. ICEs, all
20 MSI table assertions, extracted payload hashes, real client/daemon/lease
execution and unchanged MSI hashes pass. No payload processes remain after
smoke. The x64 image stays undeletable for about 22 seconds on ARM64 Windows,
then removal succeeds; ARM64 cleanup succeeds immediately. A bounded 30-second
retry replaces the insufficient 2-second window. The retaining component is
not identified; the evidence does not show a leaked RunQuota process.
