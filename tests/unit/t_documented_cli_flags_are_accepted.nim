## Every command line the user-facing documentation shows for `runquota` and
## `runquotad` must use only flags the shipped CLI defines, and the `acquire`
## usage line must state the unit of `--cpu`.
##
## Property protected: the documented flag vocabulary and the CLI agree.
## Recorded as reprobuild-pm issue
## `2026-11-12-acquire-resource-flags-are-never-defined-and-each-document-
## spells-them-differently`: the README showed `runquota run --cores 4
## --mem 8G` and `runquotad --config`, which fail outright, and the usage
## text gave `acquire --cpu N`, which hid that `N` is milli-CPU (`--cpu 2`
## reserves 0.002 of a CPU).
##
## NO MOCKS. The subject is the shipped `renderUsage` text (the string the
## binary prints), the shipped `runquotad` source's option table, and the real
## documentation files read from disk.

import std/[os, strutils, unittest]

import runquota_cli_support

const
  RepoRoot = currentSourcePath().parentDir().parentDir().parentDir()
  DocFiles = [RepoRoot / "README.md",
    RepoRoot / "docs" / "book-isonim" / "content" / "usage_guide" / "cli.md"]
  DaemonSource = RepoRoot / "apps" / "runquotad" / "runquotad.nim"

proc longFlags(line: string): seq[string] =
  ## `--name` words of a command line, ignoring everything after a bare `--`
  ## (that is the wrapped command's own flags) and any `# comment`.
  var text = line
  let hash = text.find(" #")
  if hash >= 0: text = text[0 ..< hash]
  for word in text.splitWhitespace():
    if word == "--": break
    if word.startsWith("--") and word.len > 2:
      var name = word
      let eq = name.find('=')
      if eq >= 0: name = name[0 ..< eq]
      result.add name

proc fencedCommands(path: string; program: string): seq[string] =
  var inFence = false
  for raw in readFile(path).splitLines():
    let line = raw.strip()
    if line.startsWith("```"):
      inFence = not inFence
      continue
    if inFence and line.startsWith(program & " "):
      result.add line

proc verbUsage(usage, verb: string): string =
  ## The usage lines of one verb: its `  runquota <verb>` line plus the
  ## indented prose beneath it, up to the next verb line.
  var taking = false
  for line in usage.splitLines():
    if line.startsWith("  runquota "):
      taking = line.startsWith("  runquota " & verb & " ") or
        line == "  runquota " & verb
    if taking: result.add line & "\n"

suite "documented command lines use defined flags":
  let usage = renderUsage("runquota")
  let daemonSource = readFile(DaemonSource)

  test "runquota commands in the docs use flags their verb defines":
    for path in DocFiles:
      for command in fencedCommands(path, "runquota"):
        let words = command.splitWhitespace()
        if words.len < 2: continue
        let verb = words[1]
        let section = verbUsage(usage, verb)
        if section.len == 0: continue # `runquota status` and the like
        for flag in longFlags(command):
          check section.contains(flag)
          if not section.contains(flag):
            checkpoint(path.extractFilename & ": `" & command &
              "` uses " & flag & ", which `runquota " & verb & "` lacks")

  test "runquotad commands in the docs use flags the daemon parses":
    for path in DocFiles:
      for command in fencedCommands(path, "runquotad"):
        for flag in longFlags(command):
          check daemonSource.contains("of \"" & flag & "\"")
          if not daemonSource.contains("of \"" & flag & "\""):
            checkpoint(path.extractFilename & ": `" & command &
              "` uses " & flag & ", which runquotad does not parse")

  test "the acquire usage line states the units of --cpu and --mem":
    let section = verbUsage(usage, "acquire")
    check section.contains("--cpu MILLI")
    check section.contains("--mem SIZE")
