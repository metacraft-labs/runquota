# `cgroup placement rules`' pure-path tests fail on Windows because they compare Linux cgroup paths with the native (`\`) separator

| Field | Value |
| --- | --- |
| Status | Open |
| Observed in | `runquota` @ `7c98da54` (`agents` tip); Nim 2.2.8, eli-pc (Windows 11 x86_64) |
| Area | `libs/runquota_process/tests/t_cgroup_placement.nim`: "a group name cannot leave its directory" and "cap leaves and targets" |
| Expectation | Not platform-specific: these tests model Linux cgroup v2 paths as strings, with no filesystem access, so they should pass on any host that can run Nim. |

## Observed

Two `cgroup placement rules` suite tests have no `when defined(linux):`
guard (unlike the suite's genuinely Linux-only "launching without and with
a cgroup (Linux)" sub-suite, which is guarded), yet fail on Windows:

```
target.leafPath.parentDir.parentDir was \sys\fs\cgroup\user.slice\user-1000.slice\user@1000.service\runquota.slice
root was /sys/fs/cgroup/user.slice/user-1000.slice/user@1000.service/runquota.slice
Check failed: normalizedPath(target.leafPath).startsWith(root & "/")
Check failed: target.leafPath.parentDir.parentDir == root
[FAILED] a group name cannot leave its directory
...
Check failed: capped.leafPath == "/sys/fs/cgroup/t/r/group-g/cap-42-7"
capped.leafPath was \sys\fs\cgroup\t\r\group-g\cap-42-7
Check failed: reclaimed.leafPath == "/sys/fs/cgroup/t/r/reclaimed/shared"
reclaimed.leafPath was \sys\fs\cgroup\t\r\reclaimed\shared
[FAILED] cap leaves and targets
```

The leaf paths are built from `std/os`'s `/` operator and/or `parentDir`,
which join with the HOST's native separator (`\` on Windows) rather than
the forward slash Linux cgroup paths always use. These paths never touch a
real filesystem (`cgroup_placement.nim`'s path-building here is pure string
construction over a Linux target), so the mismatch is entirely an artifact
of running the test on Windows, not a real defect in the placement logic
itself — the SAME path, with `\` in place of `/`, is what Windows's `parentDir`
and `/` actually produced.

## Suggested direction

Either build these test paths with an explicit `posix.`-style forward-slash
join (bypassing `std/os`'s native-separator operators for this
Linux-specific domain), or compare with the separator normalized on both
sides. Whichever is chosen, a Windows CI run of `libs/runquota_process`'s
own unit tests should be green; right now it is not, for a reason that has
nothing to do with the module under test.
