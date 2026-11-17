## The measurement capability record (`runquota_process/enforcement`): what
## `sizing-data` can and cannot measure of a process tree on each operating
## system, as printed by `runquota status`, `profile` and `sizing`.
##
## WHAT IS GUARDED, each with the change that makes it fail:
##
## * macOS says plainly that write bytes are the launched root's own and
##   that memory is resident size, a floor. Mutation: the macOS record
##   claiming `full` or dropping the gap.
## * Linux says `full` for both and has an empty gap. Mutation: the Linux
##   record carrying a gap, or macOS and Linux sharing one record.
## * Every OS renders the same JSON keys, with explicit values, so a
##   consumer never infers from absence. Mutation: omitting an entry or a
##   key for one OS.
## * The text and JSON renderings carry the figures' qualifiers, and the
##   JSON insertion keeps the daemon's own bytes. Mutation: `renderLines`
##   not printing the gap.
##
## NO MOCKS: the record is a pure function of the OS name, so every OS is
## checked on any host.
import std/[json, strutils, unittest]
import runquota_process

suite "measurement capability record":
  test "macOS: the root's own writes, resident size as a floor":
    let record = measurementRecordFor("macos")
    check record.os == "macos"
    check record.entries.len == 2
    check record.entries[0].quantity == mqWriteBytes
    check record.entries[0].coverage == mcPartial
    check "root process's own writes" in record.entries[0].how
    check "children's writes are not counted" in record.entries[0].gap
    check record.entries[1].quantity == mqMemory
    check record.entries[1].coverage == mcPartial
    check "resident size" in record.entries[1].how
    check "compressor" in record.entries[1].gap
    check "floor" in record.entries[1].gap

  test "linux: the whole tree, no gap":
    let record = measurementRecordFor("linux")
    check record.entries.len == 2
    for item in record.entries:
      check item.coverage == mcFull
      check item.gap.len == 0
      check "whole tree" in item.how

  test "windows and unknown systems are recorded as not measured":
    for name in ["windows", "plan9"]:
      let record = measurementRecordFor(name)
      check record.entries.len == 2
      for item in record.entries:
        check item.coverage == mcNone
        check item.gap.len > 0

  test "the JSON has the same keys on every OS":
    for name in ["linux", "macos", "windows", "plan9"]:
      let node = parseJson(measurementRecordFor(name).toJson())
      check node{"os"}.getStr() == name
      check "daemon runs on" in node{"describes"}.getStr()
      check node{"measurements"}.getElems().len == 2
      for item in node{"measurements"}.getElems():
        for key in ["quantity", "coverage", "how", "gap"]:
          check item.hasKey(key)
          check item[key].kind == JString
    let mac = parseJson(measurementRecordFor("macos").toJson())
    check mac{"measurements"}[0]{"quantity"}.getStr() == "write-bytes"
    check mac{"measurements"}[0]{"coverage"}.getStr() == "partial"
    let linux = parseJson(measurementRecordFor("linux").toJson())
    check linux{"measurements"}[0]{"coverage"}.getStr() == "full"
    check linux{"measurements"}[0]{"gap"}.getStr() == ""

  test "the text carries the qualifier and says whose host it describes":
    let lines = measurementRecordFor("macos").renderLines()
    check lines.len == 3
    check lines[0].startsWith("measurement_os: macos")
    check "not the host that recorded stored rows" in lines[0]
    check "measurement: write-bytes partial" in lines[1]
    check "gap: children's writes are not counted" in lines[1]
    check "measurement: memory partial" in lines[2]
    check "gap: pages the memory compressor holds are excluded" in lines[2]

  test "inserting the record keeps every other byte of the answer":
    let record = measurementRecordFor("macos")
    let answer = "{\"status\":\"ok\",\"quantile\":0.99}"
    let merged = withMeasurementKey(answer, record)
    check merged.endsWith(",\"status\":\"ok\",\"quantile\":0.99}")
    let node = parseJson(merged)
    check node{"status"}.getStr() == "ok"
    check node{"measurement"}{"os"}.getStr() == "macos"
    check parseJson(withMeasurementKey("{}", record)){"measurement"}.kind ==
      JObject
    check withMeasurementKey("[1]", record) == "[1]"
