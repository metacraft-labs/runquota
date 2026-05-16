import std/osproc

type
  LibraryInfo* = object
    name*: string

  LaunchResult* = object
    processId*: uint64
    running*: bool

  LaunchedProcess* = object
    handle*: Process
    info*: LaunchResult
  CommandSpec* = object
    argv*: seq[string]
    cwd*: string
