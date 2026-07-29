import std/[os, sets, strutils]

import compiler/[idents, lexer, lineinfos, llstream, options, pathutils]

type
  RefToken = object
    path: string
    line: int
    column: int

  SourceScan = object
    refTokens: seq[RefToken]
    lexicalErrors: int

proc lexicalErrorHandler(
    config: ConfigRef,
    info: TLineInfo,
    message: TMsgKind,
    argument: string,
) =
  if message in errMin .. errMax:
    inc config.errorCounter
    stderr.writeLine(
      "Nim lexical error at " & $info.line & ":" & $(info.col + 1) & ": " &
        argument,
    )

proc scanSource(path: string): SourceScan =
  let
    absolute = AbsoluteFile(absolutePath(path))
    stream = llStreamOpen(absolute, fmRead)
  if stream.isNil:
    raise newException(IOError, "cannot read Nim source: " & path)

  let
    config = newConfigRef()
    cache = newIdentCache()
  var
    sourceLexer: Lexer
    token: Token
    inBackticks = false
  openLexer(sourceLexer, absolute, stream, cache, config)
  sourceLexer.errorHandler = lexicalErrorHandler
  defer:
    closeLexer(sourceLexer)

  while true:
    rawGetTok(sourceLexer, token)
    if token.tokType == tkAccent:
      inBackticks = not inBackticks
    elif token.tokType == tkRef and not inBackticks:
      result.refTokens.add(
        RefToken(path: path, line: token.line, column: token.col + 1),
      )
    if token.tokType == tkEof:
      break

  result.lexicalErrors = config.errorCounter
  if inBackticks:
    inc result.lexicalErrors

proc reportScan(scan: SourceScan): bool =
  for token in scan.refTokens:
    stderr.writeLine(
      token.path & ":" & $token.line & ":" & $token.column &
        ": Nim ref type token found",
    )
  if scan.lexicalErrors > 0:
    stderr.writeLine("Nim source has lexical errors")
  result = scan.refTokens.len == 0 and scan.lexicalErrors == 0

proc canonicalDirectory(path, description: string): string =
  if path.len == 0:
    raise newException(ValueError, description & " must not be empty")
  result = expandFilename(absolutePath(path))
  if getFileInfo(result, followSymlink = false).kind != pcDir:
    raise newException(ValueError, description & " is not a directory: " & path)

proc canonicalFile(path, description: string): string =
  if path.len == 0:
    raise newException(ValueError, description & " must not be empty")
  result = expandFilename(absolutePath(path))
  if getFileInfo(result, followSymlink = false).kind != pcFile:
    raise newException(ValueError, description & " is not a regular file: " & path)

proc isWithin(path, root: string): bool =
  path == root or path.startsWith(root & DirSep)

proc scanClosure(
    repoRootArgument, trustedRootArgument, entryArgument, depsArgument: string,
): bool =
  let
    repoRoot = canonicalDirectory(repoRootArgument, "repository root")
    trustedRoot = canonicalDirectory(trustedRootArgument, "trusted Nim root")
    entry = canonicalFile(entryArgument, "static-helper entry")
    depsFile = canonicalFile(depsArgument, "compiler dependency manifest")

  if not entry.isWithin(repoRoot):
    raise newException(
      ValueError,
      "static-helper entry is outside repository root: " & entry,
    )

  let manifest = readFile(depsFile)
  if manifest.len == 0:
    raise newException(ValueError, "compiler dependency manifest is empty")
  if '\0' in manifest:
    raise newException(
      ValueError,
      "compiler dependency manifest contains a NUL byte",
    )
  if '\r' in manifest:
    raise newException(
      ValueError,
      "compiler dependency manifest contains a carriage-return byte",
    )

  var
    entryFound = false
    seen = initHashSet[string]()
    allClean = true
  let dependencies = manifest.splitLines()
  for index, dependency in dependencies:
    if dependency.len == 0:
      if index == dependencies.high and
          (manifest.endsWith("\n") or manifest.endsWith("\r")):
        continue
      raise newException(
        ValueError,
        "compiler dependency manifest contains an empty path",
      )
    if not dependency.isAbsolute:
      raise newException(
        ValueError,
        "compiler dependency path is not absolute: " & dependency,
      )

    let canonical = canonicalFile(dependency, "compiler dependency")
    if dependency != canonical:
      raise newException(
        ValueError,
        "compiler dependency path is not canonical: " & dependency &
          " (canonical: " & canonical & ")",
      )
    if canonical in seen:
      raise newException(
        ValueError,
        "compiler dependency manifest contains a duplicate: " & canonical,
      )
    seen.incl canonical

    if canonical == entry:
      entryFound = true
    if canonical.isWithin(repoRoot):
      if canonical.splitFile.ext != ".nim":
        raise newException(
          ValueError,
          "repository dependency is not a Nim source: " & canonical,
        )
      if not reportScan(scanSource(canonical)):
        allClean = false
    elif not canonical.isWithin(trustedRoot):
      raise newException(
        ValueError,
        "compiler dependency is outside repository and trusted Nim roots: " &
          canonical,
      )

  if not entryFound:
    raise newException(
      ValueError,
      "compiler dependency manifest does not contain its entry: " & entry,
    )
  result = allClean

proc usage() =
  stderr.writeLine(
    "usage:\n" &
      "  nim_ref_token_scanner scan -- <Nim source>...\n" &
      "  nim_ref_token_scanner closure <repo-root> <trusted-root> " &
      "<entry> <compiler-deps>",
  )

when isMainModule:
  try:
    if paramCount() >= 2 and paramStr(1) == "scan" and paramStr(2) == "--":
      if paramCount() < 3:
        raise newException(ValueError, "scan requires at least one Nim source")
      var clean = true
      for index in 3 .. paramCount():
        if not reportScan(scanSource(paramStr(index))):
          clean = false
      if not clean:
        quit 1
    elif paramCount() == 5 and paramStr(1) == "closure":
      if not scanClosure(paramStr(2), paramStr(3), paramStr(4), paramStr(5)):
        quit 1
    else:
      usage()
      quit 2
  except CatchableError as error:
    stderr.writeLine("Nim ref token gate error: " & error.msg)
    quit 2
