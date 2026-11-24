## The daemon's admission counters: lease requests refused, by reason, and
## how long granted leases waited in the queue, as a counter and as a
## cumulative histogram. Inspection output only (`status --json`): the
## daemon decides nothing from them.
##
## Specified in reprobuild-pm `spec/Build-Engine-And-Scheduler.md`
## §"Admission counters, budget and host identity in `status --json`". The
## histogram follows the Prometheus histogram convention
## (<https://prometheus.io/docs/concepts/metric_types/#histogram>): bucket
## `i` counts the observations at most `le_micros[i]`, so the buckets are
## cumulative, and `count` is the `+Inf` bucket.
##
## Every counter saturates at `high(uint64)` rather than wrapping, like the
## `capacity` figures (`capacity_metrics.saturatingAdd`): a reader that
## takes the difference of two scrapes must never see a counter go down.

import std/strutils

import ./capacity_metrics

type
  RejectionReason* = enum
    ## Why a lease request was refused. Exactly one per refusal.
    rejectBudget = "budget"
      ## The request can never fit what the daemon enforces: the host, a
      ## pool, a class, or the parent lease of a sub-lease.
    rejectWaitLimit = "wait_limit"
      ## The request was queued and then refused: it waited past a bound,
      ## or the daemon dropped it from the queue.
    rejectRefused = "refused"
      ## A policy refusal of an otherwise valid request: a benchmark lease
      ## the session may not take, a session the connection does not own.
    rejectInvalid = "invalid"
      ## A request that could not be read, or whose arguments are malformed.

  AdmissionCounters* = object
    ## Monotonic from daemon start.
    totalRejected*: uint64
    rejected*: array[RejectionReason, uint64]
    totalWaitMicros*: uint64
      ## The queue time of every grant counted in `waitCount`, summed.
    waitCount*: uint64
      ## Grants observed; equals the daemon's `totalGranted`.
    waitBuckets*: array[7, uint64]
      ## Cumulative: `waitBuckets[i]` counts the waits at most
      ## `LeaseWaitBoundsMicros[i]`.

const
  LeaseWaitBoundsMicros* = [1_000'u64, 10_000, 100_000, 1_000_000,
    10_000_000, 60_000_000, 600_000_000]
    ## 1 ms to 10 min. Fixed, so two daemons' histograms can be summed.

proc noteRejected*(counters: var AdmissionCounters; reason: RejectionReason;
                   count = 1'u64) =
  ## `count` lease requests refused for `reason`.
  counters.totalRejected = saturatingAdd(counters.totalRejected, count)
  counters.rejected[reason] = saturatingAdd(counters.rejected[reason], count)

proc noteGrantWait*(counters: var AdmissionCounters; waitedMicros: uint64) =
  ## One grant, after `waitedMicros` in the queue (0 when granted at once).
  counters.totalWaitMicros = saturatingAdd(counters.totalWaitMicros,
    waitedMicros)
  counters.waitCount = saturatingAdd(counters.waitCount, 1'u64)
  for i, bound in LeaseWaitBoundsMicros:
    if waitedMicros <= bound:
      counters.waitBuckets[i] = saturatingAdd(counters.waitBuckets[i], 1'u64)

proc rejectedJson*(counters: AdmissionCounters): string =
  ## `"total_rejected":N,"rejected":{...}` -- members, not an object, so the
  ## caller places them beside the wire status.
  var parts: seq[string] = @[]
  for reason in RejectionReason:
    parts.add("\"" & $reason & "\":" & $counters.rejected[reason])
  "\"total_rejected\":" & $counters.totalRejected &
    ",\"rejected\":{" & parts.join(",") & "}"

proc waitJson*(counters: AdmissionCounters): string =
  ## `"total_wait_micros":N,"lease_wait_histogram":{...}` (members).
  var bounds: seq[string] = @[]
  for bound in LeaseWaitBoundsMicros: bounds.add($bound)
  var buckets: seq[string] = @[]
  for bucket in counters.waitBuckets: buckets.add($bucket)
  "\"total_wait_micros\":" & $counters.totalWaitMicros &
    ",\"lease_wait_histogram\":{\"le_micros\":[" & bounds.join(",") &
    "],\"buckets\":[" & buckets.join(",") & "],\"count\":" &
    $counters.waitCount & ",\"sum_micros\":" & $counters.totalWaitMicros & "}"
