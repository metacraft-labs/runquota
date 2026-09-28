# Windows compile gate requires a missing environment script

- Status: open
- Observed in: `0e608b209a8813ced2d9b0e25f3450aad631b5c8`

The clean Windows 2025 runner reaches setup-dev-env, then fails because
`env-flavor: windows-diy` requires `./env.ps1`. RunQuota has no such file.
The previous persistent-runner checkout failure hid this setup error.

The native compile gate in `.github/workflows/ci.yml` must provision the
toolchain before compiling every entrypoint and library and running the
portable test manifest. This is also required by the validation plan in
metacraft-specs/infrastructure/gosti-io-mon-runquota-releases.md.

Use the release workflow's checksum-pinned Nim and LLVM-MinGW setup at
`metacraft-github-actions@f450cb0d688fb7d15cd475c792b1c9b6acae87c5`, and pass
the selected compiler explicitly to both native compilation steps. Keep
the complete existing compile, type-check, smoke and test coverage.

Evidence: [Windows setup failure](https://github.com/metacraft-labs/runquota/actions/runs/36427055782/job/108943495540).
Searched current and archived issues after syncing dev and agents; no earlier
issue records the absent script.
