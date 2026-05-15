import std/unittest
import runquota_core

suite "RunQuota version":
  test "version is exposed by the core library":
    check versionString() == "0.1.0"
