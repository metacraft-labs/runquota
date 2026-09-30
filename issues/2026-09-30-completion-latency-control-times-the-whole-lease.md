# Completion-report latency control times the whole lease lifecycle

Status: open. RunQuota `8322c3f`, Windows x64 ordinary Reprobuild job
`109825532418` in run `36696456249`.

## Observed

The complete monitored build passes. Execution fails only
`t_completion_report_does_not_wait_on_the_store`: the keyless median is
2.0367 ms against the 2 ms control ceiling. The keyed median is 2.1118 ms.
All drain, coalescing and final-publication assertions pass: zero synchronous
drains, one publication and 39 coalesced requests for 40 completions.

`timeOneCompletion` starts its monotonic timer before `requestLease` and
stops after `release`. It includes admission, `markStarting`, `markRunning`,
`finish` and `release`. This is not the old wall-clock defect: `718598e`
already replaced that clock, and the current source uses `getMonoTime`.
The measured excess does not establish blocking in the completion handler.

## Expected and investigation

[Observation Store OS-1](../../reprobuild-specs/RunQuota-Observation-Store.md)
requires observation recording not to block. This fixture targets the former
synchronous store drain in `LeaseFinished`. The spec does not require the
whole five-operation lifecycle to take less than 2 ms.

Proposed: first measure each operation on the same real daemon and compiler,
under the same monitored recipe. Compare the existing whole-lifecycle timer
with a timer around `finish`, keeping the 2 ms control ceiling, paired
comparison, counts and publication assertions. Retain the complete lifecycle
measurement as diagnostic output. Restore a real synchronous store flush in
a disposable daemon as a positive regression control; the corrected fixture
must reject it for actual synchronous drains and latency. No production
runtime change or threshold increase is proposed without this evidence.

Fetched dev `0bce530`, already an ancestor, and agents `8322c3f`. Searched
open and deleted records for keyless latency, the test name and whole
lifecycle measurements. The existing wall-clock issue covers a different
measurement defect; the daemon-deadline issue covers startup/retention bounds.

## Candidate validation

[Control `36703882925`](https://github.com/metacraft-labs/metacraft-github-actions/actions/runs/36703882925)
at shared `219c22e`, RunQuota `8322c3f`, passes its complete Windows x64 job.
The completion-only keyed/keyless medians are 0.6827/0.6914 ms; the same
keyless lifecycle is 2.1842 ms. Restoring a real synchronous writer flush
fails both required checks with 54 drains and 110.8726/0.5210 ms completion
medians. Every variant launches the actual fixture. The ARM-host job remains
active as the candidate is prepared.

The final fixture patch retains the whole lifecycle as diagnostic output,
while the unchanged 2 ms ceiling and paired comparison apply to `finish`.
At `ed40495` plus that patch, local macOS execution passes with completion
medians 0.0217/0.0208 ms and one drain. The same fixture rejects the real
synchronous regression with 46 drains and medians 6.2178/0.0240 ms. Windows
Nim checking passes. Complete ordinary candidate CI remains required.
