import std/[os, strutils, unittest]

import runquota_cli_support

suite "RunQuota daemon program path":
  test "uses the platform executable suffix":
    let path = daemonProgramPath()
    check path.endsWith(addFileExt("runquotad", ExeExt))
