# RunQuota Documentation

This directory contains public user and implementation documentation for the
RunQuota repository.

- [`book-isonim/`](./book-isonim/README.md) — the **user-facing book**: what
  RunQuota is, provisioning a host, the daemon, the CLI, and the observation
  store. Built with the `isonim-docs` static-site framework. Start at
  `book-isonim/content/`; its README explains the sibling checkouts the build
  needs and why it is skipped from the build graph without them.
- [`database.md`](./database.md) — the observation store's design and schema,
  written for implementers.
- [`repository-requirements.md`](./repository-requirements.md) — how this
  repository satisfies the Metacraft repository requirements.
