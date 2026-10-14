## The POSIX controls use a real daemon and real decisions. The inert client
## below is justified solely to prove argument refusal precedes transport I/O;
## it never stands in for an authority, a grant, or a successful lease.
import std/[os, unittest]
import runquota_client, runquota_core

when defined(posix):
  import bounded_request_transport
  if paramCount() > 0 and paramStr(1) == "--request-probe":
    requestProbe(paramStr(2), paramStr(3))
    quit(0)
  if paramCount() > 0 and paramStr(1) == "--transport-proxy":
    transportProxy(paramStr(2), paramStr(3), paramStr(4))
    quit(0)

suite "bounded immediate lease requests":
  test "invalid bounds refuse before emitting a request":
    var client = RunQuotaClient(state: csConnected)
    var session = RunQuotaSession(client: addr client, active: true)
    let request = resourceRequest("invalid-bound", milliCpu(100), bytes(1024))
    var invalidBounds = @[-1]
    when sizeof(int) > sizeof(int32):
      invalidBounds.add(high(int))
    for timeout in invalidBounds:
      expect RunQuotaClientError:
        discard session.requestLease(request, timeoutMs = timeout)
      check client.nextRequestId == 0
      check session.active
    when defined(windows):
      expect RunQuotaClientError:
        discard session.requestLease(request, timeoutMs = 100)
      check client.nextRequestId == 0
      check session.active

  when defined(posix):
    test "real decisions preserve default/denial semantics and reclaim uncertainty":
      var modes = @["default", "default-delayed", "finite", "negative",
        "denial", "timeout", "malformed", "unrelated"]
      when sizeof(int) > sizeof(int32):
        modes.add("overflow")
      for mode in modes:
        realTransportScenario(mode)
