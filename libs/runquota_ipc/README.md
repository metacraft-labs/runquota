# runquota_ipc

Local IPC transports for RQSP frames.

On POSIX, a positive `sendFrame` `timeoutMs` bounds the whole frame write
with a monotonic deadline, polling for writability before nonblocking partial
sends. Zero (the default) retains blocking writes. The diagnostic overload
returns false with `diagProtocol` on timeout; OS failures still raise.
The convenience overload raises on failure. Discard a connection after a
failed write because the peer may have received only part of the frame; a
timeout after a partial frame shuts the socket down in both directions, so
later writes fail and the peer reads end of input.

Client control handshakes and bounded request paths pass their read timeout
to the write too. Write and read budgets are separate, not a single round-trip
deadline. Daemon response writes retain their default unbounded behaviour.

Windows named-pipe writes remain synchronous: they accept the timeout argument
but do not enforce it. Named-pipe read deadlines are unchanged.
