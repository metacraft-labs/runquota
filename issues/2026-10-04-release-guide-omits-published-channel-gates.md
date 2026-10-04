# Release guide omits published channel gates

| | |
| --- | --- |
| Status | open |
| Recorded | 2026-10-04 |
| Observed in | RunQuota `f47e9098389a7255069d56415f46362f1a010a50` |
| Area | `docs/releasing.md` |

## Observed

The guide's final distribution paragraph calls Homebrew and nixpkgs future
work outside the staged release, and its publication sequence omits their
live checks and Scoop's. Version 0.1.2 has already passed those channels at
`2b04e6e`; the guide still calls that version a preparation candidate.

## Expected

The shared [release specification](https://github.com/metacraft-labs/metacraft-pm/blob/latest/infrastructure/gosti-io-mon-runquota-releases.md)
requires all declared channel publication and live installation checks before
stable promotion. The guide must describe those current gates and distinguish
published 0.1.2 from the next 0.1.3 preparation. The shared installer remains a
proposal, so the guide must not claim its deployment.

## Evidence and search

Fetched current `agents` and the shared promotion branch at `f47e9098`.
Inspected **Release sequence**, the following distribution paragraph and
**Current stabilization candidate**. Searched open and resolved issues for the
guide and distribution scope; the archived host-configuration and version-test
reference issues concern separate defects. The shared conformance issue
records the broader channel gaps and Gosti's parallel guide correction.
