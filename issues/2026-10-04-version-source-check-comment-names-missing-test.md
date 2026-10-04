# Packaging version comment names a nonexistent test

At mainline `f369c34` and agents `2510251`, the comment beside
`RunQuotaPackageVersion` directs readers to
`tests/unit/t_version_sources_agree`, which is absent from the current tree
and file history. The actual three-source equality case lives in
`tests/unit/t_packaging_contract.nim`. Open issues and resolved issue history
were checked before recording this mismatch.

`docs/releasing.md` requires updating and verifying every version source.
The code comment should point to the real gate so a release operator can run
it. Correct the reference without moving or changing any assertion.
