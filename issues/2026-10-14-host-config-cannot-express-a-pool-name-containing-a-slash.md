# The host config cannot express a pool name containing `/`, so the pools Reprobuild actually declares can never be sized by an operator

| Field | Value |
| --- | --- |
| Status | Open |
| Observed in | `runquota` @ `86bf4711f` (`agents` tip, up to date with origin); CLI `runquota 0.1.3` from `/Users/zahary/.nix-profile/bin/runquota`; macOS aarch64-darwin, 2026-10-14 |
| Area | `isBareKey()` / `parseHostConfigKey()` in `libs/runquota_daemon/src/runquota_daemon/host_config.nim` |
| Expectation | Not specified in a runquota doc. Proposed below, grounded in the consumer's naming. |

## Observed

`runquota config set` refuses any pool whose name contains `/`:

```
$ runquota config set pools.vcs/fetch 8
runquota config set: pool name `vcs/fetch` must be letters, digits, `_` or `-`
```

The rule is `isBareKey()`, which admits only `[A-Za-z0-9_-]`, with the stated
reason in `parseHostConfigKey()`:

```nim
# A pool name is a bare TOML key. Anything else would need quoting, and
# the reader does not model quoted keys.
if not result.name.isBareKey:
  raise newException(HostConfigError, "pool name `" & result.name &
    "` must be letters, digits, `_` or `-`")
```

But `/` is exactly the convention Reprobuild's engine uses for the pools it
declares over the wire. In `reprobuild` @ `f24884244`:

```nim
const SyncFetchPool = "vcs/fetch"        # libs/repro_cli_support/src/repro_cli_support.nim
...
graph(cloneActions, @[pool("vcs/fetch", 8'u32)])
```

So the set of pool names the daemon can be *told about* by a build
(`DeclarePools`, which applies no such character restriction) is strictly
larger than the set an operator can *size* in the host file. For
`vcs/fetch` — a pool reprobuild uses on every `repro sync` fetch — there is no
operator-reachable capacity setting at all.

This is reachable in practice. With a daemon that predates pool declarations,
`repro sync` refuses its fetches with a message naming `vcs/fetch`, and the
documented lighter remedy (`runquota config set pools.vcs/fetch N`, which
reloads rather than restarts) cannot be executed: the validator rejects the
key before the daemon is ever contacted.

## Expected

Not specified in a runquota doc. **Proposed:** a pool name that the daemon
will accept over `DeclarePools` must also be expressible in the host
configuration file. The two surfaces name the same objects, so a name that is
legal for one and illegal for the other makes the configuration file unable to
describe the daemon's actual state.

The reason given for the restriction is an implementation property of the
reader ("the reader does not model quoted keys"), not a decision about what a
pool may be called — TOML itself permits `"vcs/fetch"` as a quoted key. That
makes this a gap rather than a deliberate limitation, but it should be
confirmed by whoever owns the naming convention before it is changed: the
alternative resolution is to constrain *Reprobuild's* pool names to bare keys,
which is a change in the other repo.

## Evidence

Measured 2026-10-14, aarch64-darwin:

```sh
$ runquota --version
runquota 0.1.3

$ runquota config path
/etc/runquota/runquotad.toml

$ runquota config set pools.vcs/fetch 8
runquota config set: pool name `vcs/fetch` must be letters, digits, `_` or `-`
```

Consumer side, `reprobuild` @ `f24884244`:

```sh
$ grep -n 'SyncFetchPool = ' libs/repro_cli_support/src/repro_cli_support.nim
41056:const SyncFetchPool = "vcs/fetch"
```

**Inferred, not measured:** that `DeclarePools` imposes no character
restriction. This is read from the absence of a validator on that path and
from reprobuild successfully declaring `vcs/fetch`; it was not exercised
against a daemon new enough to accept declarations. A reviewer should confirm
with `t_pool_declarations.nim` before acting on it.

## Related

Observed while diagnosing a separate condition on the same host: the running
daemon is a `0.1.0` build started with `--pool compile=8 --pool fetch=2`, so it
predates pool declarations entirely and `runquota config show` reports
`(this runquotad predates host-configuration reload)`. For that daemon the
capacity is additionally pinned by the spawn-time flag — `reprobuild`'s
`declareRunQuotaPools` doc comment notes that a `--pool` flag "pins the pool
for the daemon's whole life (the host file and `runquota config set
pools.NAME` could not change it)". Those are separate conditions from this
one: this issue is that the key cannot be *written* even for a daemon that
would honour it.
