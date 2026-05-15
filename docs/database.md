# Database Posture

M0 does not introduce a production shared database. Future RunQuota persistence
uses local daemon metadata and must document schema ownership, migrations,
backup, restore, corruption handling, and benchmarks before becoming a stable
state boundary.

JSON may be emitted for inspection output, diagnostics, or benchmark reports.
It must not define persistent or wire state.
