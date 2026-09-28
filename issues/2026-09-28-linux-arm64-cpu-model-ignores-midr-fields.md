# Linux ARM64 CPU model detection ignores the available MIDR fields

| | |
|---|---|
| Status | in-progress on `agents`; native ARM64 verification pending |
| Recorded | 2026-09-28 |
| Observed in | runquota @ `74aacfe88cbfe13d12a95aa380a53bc706943c16` |
| Area | `runquota_observation_store/hardware.nim`, `cpuModelOf` |

## Observed

The complete Linux ARM64 suite compiled and ran all 95 test programs; 93 passed.
`t_observation_store_host_profile` and
`t_observation_store_degraded_capture_build` failed their checks that
`cpuModel != unknownField`. Both received `unknown`.

`cpuModelOf` searches textual model names only. Linux ARM64's kernel
`c_show` emits CPU implementer, architecture, variant, part and revision;
`model name` is emitted only for the 32-bit compatibility personality.
The failing job did not print `/proc/cpuinfo`, so the precise host identifiers
remain unmeasured.

## Expected

[`RunQuota-Observation-Store.md`, `hosts` and `host_profiles`](../../reprobuild-specs/RunQuota-Observation-Store.md)
requires detection of descriptive hardware facts and a stable profile hash.
Available CPU identity must not be discarded merely because the architecture
uses numeric identity fields. Detection must still return `unknown` when the
input does not contain a usable identity.

## Evidence

- [Full native ARM64 job](https://github.com/metacraft-labs/runquota/actions/runs/36453671722/job/109034430766)
  at `74aacfe`.
- [Linux ARM64 CPU information producer](https://github.com/torvalds/linux/blob/master/arch/arm64/kernel/cpuinfo.c),
  `c_show`.
- Synced `origin/dev` at `f4f0f93`, already an ancestor of the observed commit.
  Searched current issues and `git log --all -G 'cpuModel|cpu.model|cpuinfo'
  -- issues/`; no existing issue matched.

## Suggested direction

Retain textual names where available. Otherwise describe the kernel's ARM
implementer/part identity directly, without guessing a marketing name. Keep
distinct heterogeneous CPU identities in deterministic order. Exercise the
parser with actual kernel-format input and repeat the complete native ARM64
suite, retaining the existing assertions.

## Repair validation

The candidate based on `2ddbf11` extracts the CPU parser into
`linux_cpu_model.nim`, retains textual names, and falls back to sorted distinct
ARM implementer/part/variant/revision identities. Missing identity stays unknown.
Nine parser cases and all eleven native macOS host-profile cases pass locally;
the Linux ARM64 detector typechecks. The old parser from `74aacfe` fails the
new ARM64 regression. Complete native Linux ARM64 validation remains pending.
