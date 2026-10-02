# `sendFrame` is an unbounded blocking write, directly below a read on the same handshake that polls against a deadline

| | |
|---|---|
| Status | open |
| Recorded | 2026-10-01 |
| Observed in | `runquota` @ `f8ddbce` (`origin/agents`, synced 2026-10-01) |
| Area | `sendFrame` (`libs/runquota_ipc/src/runquota_ipc.nim`) |

## Observed

The write half of the RQSP frame pair has no deadline and no poll gate:

```nim
proc sendFrame*(connection: var LocalConnection; frame: string) =
  case connection.kind
  of endpointUnixSocket:
    # A frame must be delivered or fail. SafeDisconn suppresses EPIPE and can
    # leave std/net.send retrying a closed peer without making progress.
    connection.socket.send(frame, flags = {})
```

It takes no `timeoutMs` parameter, so a caller cannot ask for one, and no
`SO_SNDTIMEO` is set anywhere in `libs/runquota_ipc/` (`grep -rn
'SO_SNDTIMEO\|setSockOpt' libs/runquota_ipc/src/` finds nothing). A peer that
accepts the connection, never reads, and lets its receive buffer fill blocks
the caller in `send` indefinitely.

Forty-nine lines above it, `readExactSocket` has exactly the machinery that is
missing, and its docstring records the incident that put it there:

> When `timeoutMs > 0` the read is bounded by an absolute deadline: a blocking
> `recv` that would have to hit the kernel is first gated behind a
> `poll(POLLIN)` for the remaining budget, and the read fails (returns false)
> if the peer goes quiet. This is used ONLY for the client connection
> handshakes (Hello / RegisterSession / CloseSession): a runquota daemon that
> accepts the connection but never returns a complete frame — a wedged, stale,
> or protocol-incompatible daemon — would otherwise block the client forever
> in `recv`. (Observed on macOS in the reprobuild dev-env exec suite, where a
> healthy-but-silent runquotad left `repro exec` wedged for hours because the
> handshake had no timeout, so the engine's documented
> `fallbackToRunQuotaBypass` degradation never engaged.)

The three handshakes that docstring names are the same three that go out
through `sendFrame`: `runquota_client.nim`'s request helper
(`client.connection.sendFrame(encodeFrame(kind, FrameFlagRequest, requestId,
payload))`) is what sends Hello, RegisterSession and CloseSession. So the
handshake is bounded in one direction only. A daemon wedged *before* it reads
produces the identical user-visible outcome the read-side fix was written to
prevent — `repro exec` blocked indefinitely, with the documented
`fallbackToRunQuotaBypass` degradation never reached — and the deadline the
caller passed does not cover it.

`runquota_daemon.nim` sends its responses through the same proc, so the
exposure is symmetric: a client that stops reading blocks the daemon's
response write on a connection the daemon cannot abandon.

## Expected

Not specified. `RunQuota-Protocol-And-Client-Libraries.md` (in
`reprobuild-specs`) carries `timeout_millis` on the lease *request* and a
`timeout/deadline` field in the request contents, but says nothing about
bounding the transport operations that carry a frame; nothing in `docs/`
does either. Proposed:

1. **Give `sendFrame` the same `timeoutMs` parameter `receiveFrame` has**, with
   the same meaning — `poll(POLLOUT)` for the remaining budget before a write
   that would have to hit the kernel, fail rather than block when the budget is
   gone — and the same default of `0` for the long-running paths, so nothing
   that legitimately blocks today changes.
2. **Pass it from the handshakes.** A deadline on the read and none on the
   write does not bound the handshake; it bounds half of it. The caller that
   passes `timeoutMs` to `receiveFrame` should pass it here.
3. **`sendFrame` returning `void` is part of the problem.** `receiveFrame`
   returns `bool` and carries a `Diagnostic`; `sendFrame` raises or succeeds.
   A timeout is not an exceptional condition on this path — it is the signal
   that degradation should engage — so it wants the same shape.

Note the buffering hazard `readExactSocket` documents has a counterpart here:
`Socket` is buffered by default, so a `poll(POLLOUT)` gate must not be placed
where Nim's userspace send buffer makes the kernel fd's writability the wrong
question. Whoever writes this should read that docstring's CRITICAL note first.

## Evidence

A reading of synced source; **no behaviour measured, and this cannot affect the
orphaned daemons it was found next to** — an orphan has no clients, so nothing
fills its buffers. Cited from `runquota` `f8ddbce` (`origin/agents`):

- `libs/runquota_ipc/src/runquota_ipc.nim` — `sendFrame`, `readExactSocket`,
  `receiveFrame`, `readExact`.
- `libs/runquota_client/src/runquota_client.nim` — the request helper that
  sends the three handshake frames.
- `libs/runquota_daemon/src/runquota_daemon.nim` — the response and error
  senders.

The reproduction is a fixture peer that accepts and never reads, plus a frame
larger than the socket's send buffer; `tests/unit/t_disconnected_frame_write.nim`
already builds the neighbouring case (a peer that has *closed*) and is the
place to put it.

**Archive search.** `git log -i -S'sendFrame' --format='%h %as %s' -- issues/`
returns nothing: no issue in this repo, open or resolved, has ever mentioned
this symbol. Searched also for `timeout`, `handshake` and `poll` across
`issues/` and found nothing about the transport write path.

## Related

- `reprobuild-specs/RunQuota-Protocol-And-Client-Libraries.md` — the protocol
  surface that would have to say something for this to be a conformance defect
  rather than a proposal.
