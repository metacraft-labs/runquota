import std/unittest

import runquota_c

suite "RunQuota C ABI layout":
  test "resource request v1 carries a stable size field":
    check rq_abi_layout_ok()
    check rq_resource_request_v1_size() == uint32(sizeof(RqResourceRequestV1))
    let version = rq_abi_version()
    check version.major == 1'u16
    check version.minor == 0'u16

  test "status codes keep their v1 numeric values":
    check ord(rqOk) == 0
    check ord(rqErrUnavailable) == 1
    check ord(rqErrUnsupportedVersion) == 2
    check ord(rqErrDenied) == 3
    check ord(rqErrProtocol) == 5
