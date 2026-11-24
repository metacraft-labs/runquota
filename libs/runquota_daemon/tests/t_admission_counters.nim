## The admission counters' arithmetic (`runquota_daemon/admission_counters`):
## the refusal split, the cumulative lease-wait histogram and saturation.
## The daemon's use of them -- which refusal is counted under which reason,
## and that every grant is observed -- is
## `tests/integration/t_admission_counters_in_status.nim`.
##
## WHAT IS GUARDED, each with the mutation that breaks it:
##
## 1. The reasons add up to `totalRejected`. Mutation: count the total only
##    for one reason.
## 2. A wait exactly on a bound is in that bucket (`le`, "less than or
##    equal", the Prometheus convention), and every bucket above it counts
##    it too. Mutation: `<` for `<=`, or a non-cumulative bucket.
## 3. Counters saturate at `high(uint64)` rather than wrapping. Mutation:
##    plain `+`.
## 4. The JSON carries the fixed bounds, `count` and `sum_micros`.
##
## No mocks: pure functions over plain values.

import std/[json, unittest]

import runquota_daemon/admission_counters

suite "admission counters":
  test "the reasons add up to the total":
    var counters: AdmissionCounters
    counters.noteRejected(rejectBudget)
    counters.noteRejected(rejectInvalid, 3)
    counters.noteRejected(rejectWaitLimit)
    check counters.totalRejected == 5
    check counters.rejected[rejectBudget] == 1
    check counters.rejected[rejectInvalid] == 3
    check counters.rejected[rejectWaitLimit] == 1
    check counters.rejected[rejectRefused] == 0
    let parsed = parseJson("{" & counters.rejectedJson() & "}")
    check parsed["total_rejected"].getInt == 5
    check parsed["rejected"]["budget"].getInt == 1
    check parsed["rejected"]["wait_limit"].getInt == 1
    check parsed["rejected"]["refused"].getInt == 0
    check parsed["rejected"]["invalid"].getInt == 3

  test "a wait on a bound is in that bucket and every bucket above it":
    var counters: AdmissionCounters
    counters.noteGrantWait(0)
    counters.noteGrantWait(1_000)
    counters.noteGrantWait(1_001)
    counters.noteGrantWait(700_000_000)
    check counters.waitCount == 4
    check counters.totalWaitMicros == 700_002_001'u64
    check counters.waitBuckets[0] == 2      # 0 and 1000
    check counters.waitBuckets[1] == 3      # + 1001
    check counters.waitBuckets[6] == 3      # 700 s is above 10 min
    for i in 1 ..< counters.waitBuckets.len:
      check counters.waitBuckets[i] >= counters.waitBuckets[i - 1]

  test "the counters saturate":
    var counters: AdmissionCounters
    counters.noteGrantWait(high(uint64))
    counters.noteGrantWait(5)
    check counters.totalWaitMicros == high(uint64)
    counters.noteRejected(rejectBudget, high(uint64))
    counters.noteRejected(rejectBudget)
    check counters.totalRejected == high(uint64)
    check counters.rejected[rejectBudget] == high(uint64)

  test "the histogram JSON":
    var counters: AdmissionCounters
    counters.noteGrantWait(50_000)
    let parsed = parseJson("{" & counters.waitJson() & "}")
    check parsed["total_wait_micros"].getInt == 50_000
    let histogram = parsed["lease_wait_histogram"]
    check histogram["count"].getInt == 1
    check histogram["sum_micros"].getInt == 50_000
    check histogram["le_micros"].len == LeaseWaitBoundsMicros.len
    check histogram["le_micros"][0].getInt == 1_000
    check histogram["le_micros"][6].getInt == 600_000_000
    check histogram["buckets"][1].getInt == 0
    check histogram["buckets"][2].getInt == 1
