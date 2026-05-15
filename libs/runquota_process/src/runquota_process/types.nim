type
  LibraryInfo* = object
    name*: string
  CommandSpec* = object
    argv*: seq[string]
    cwd*: string
