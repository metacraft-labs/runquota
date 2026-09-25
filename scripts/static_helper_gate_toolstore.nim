## The static-helper gate's driver under the TOOL-STORE authority.
##
## Compiled and started by `scripts/static_helper_gate_toolstore.sh`, which
## has already established the authority this trusts: a Nim compiler FRESHLY
## extracted from the release archive whose SHA-256 is pinned in
## `scripts/static_helper_gate_toolstore.pins`, a gcc and a git whose tool-
## store receipts carry their pinned identities, and a snapshot of the source
## whose git tree ids it recorded. This module is the Windows-native form of
## what the Nix arm does in `check_static_helpers.sh`,
## `bootstrap_nim_ref_token_scanner.sh`, `validate_nim_scanner_deps.sh` and
## `test_nim_ref_token_scanner.sh`, case for case:
##
## 1. the work root is private to this account, and the snapshot is exactly
##    the recorded tree (re-verified with git);
## 2. the ref scanner is bootstrapped from the snapshot's
##    `nim_ref_token_scanner.nim`, copied into an empty private directory,
##    by the verified compiler, and its dependency manifest is proved to
##    name only that copy and the verified compiler's own `compiler/` and
##    `lib/` -- the LEXER AUTHORITY, which is what stops a repository from
##    shadowing the lexer the scanner is built from;
## 3. the gate's own regression suite runs: every refusal the authority,
##    the manifest validator, the bootstrap and the scanner make is provoked
##    and asserted, next to the acceptance that would otherwise let "refuse
##    everything" pass;
## 4. every library in `libs/static_helpers.txt` compiles with `--mm:arc
##    --app:staticlib`, and its compiler-reported dependency closure is
##    scanned for `ref`;
## 5. the snapshot is re-verified against the recorded tree, so nothing the
##    compilations ran could have changed what was scanned.
##
## WINDOWS SEMANTICS, NOT POSIX ONES, AND NOTHING SKIPPED. Where the Nix arm
## asks POSIX a question, this asks Windows the equivalent one: a private
## directory is an owner-only DACL (the rule `docs/database.md` states for
## the host state directory), an unreadable file is a DENY-read ACE, and a
## symbolic link is a native one -- which needs `SeCreateSymbolicLinkPrivilege`
## (an elevated shell, or Developer Mode), and FAILS the suite, by name, where
## it cannot be created. The C compiler is gcc (the dev shell's), where the
## Nix arm uses clang: the property checked is Nim's ARC static-library code
## generation, which does not depend on which C compiler assembles it.
##
## Standard library only, plus the snapshot's own
## `runquota_host_windows/security` fact reader; the front script refuses a
## build of this driver whose dependency manifest names anything else.

import std/[json, os, osproc, sets, strtabs, streams, strutils]

when not defined(windows):
  {.error: "the tool-store static-helper gate driver is Windows-only; " &
    "on Linux and macOS the gate's authority is the Nix dev shell".}

import std/winlean
import runquota_host_windows/security

type
  GateError = object of CatchableError

  Config = object
    host, nimRoot, gccBin, git, repo, gitCommonDir, sourceTree: string
    snapshot, work, ownerSid, front, bash, callerPath: string
    authorityFile: string
    subtrees: seq[(string, string)]

const
  systemSid = "S-1-5-18"
  administratorsSid = "S-1-5-32-544"
  sourcePaths = ["libs", "scripts", "tests/fixtures/static-helper-ref-scanner"]
  requiredCompilerModules = ["idents.nim", "lexer.nim", "lineinfos.nim",
    "llstream.nim", "options.nim", "pathutils.nim"]
  refFinding = "Nim ref type token found"

proc refuse(message: string) {.noreturn.} =
  raise newException(GateError, message)

# ---------------------------------------------------------------------------
# Paths: the Windows answer to `realpath`
# ---------------------------------------------------------------------------

proc getFinalPathNameByHandleW(handle: Handle; buffer: WideCString;
                               size: DWORD; flags: DWORD): DWORD {.
  stdcall, dynlib: "kernel32", importc: "GetFinalPathNameByHandleW".}

proc finalPath(path: string): string =
  ## Every link and junction resolved, the true case of every component, no
  ## 8.3 short names. The same resolution `nim_ref_token_scanner.nim` makes,
  ## so the paths this driver expects in a finding are the paths the scanner
  ## reports.
  let handle = createFileW(newWideCString(expandFilename(path)), 0'i32,
    FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE, nil,
    OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, 0)
  if handle == INVALID_HANDLE_VALUE:
    refuse("cannot open for final-path resolution: " & path)
  defer: discard closeHandle(handle)
  var buffer = newWideCString("", 32768)
  let length = getFinalPathNameByHandleW(handle, buffer, 32767, 0)
  if length == 0 or length >= 32767:
    refuse("cannot resolve the final path of: " & path)
  result = $buffer
  const uncPrefix = r"\\?\UNC\"
  const longPrefix = r"\\?\"
  if result.startsWith(uncPrefix):
    result = r"\\" & result[uncPrefix.len .. ^1]
  elif result.startsWith(longPrefix):
    result = result[longPrefix.len .. ^1]

proc samePath(a, b: string): bool =
  ## Windows paths compare without case.
  cmpIgnoreCase(a, b) == 0

proc isWithin(path, root: string): bool =
  samePath(path, root) or path.toLowerAscii.startsWith(
    (root & DirSep).toLowerAscii)

proc isLink(path: string): bool =
  try:
    getFileInfo(path, followSymlink = false).kind in {pcLinkToFile, pcLinkToDir}
  except OSError:
    false

proc isRegularFile(path: string): bool =
  try:
    getFileInfo(path, followSymlink = false).kind == pcFile
  except OSError:
    false

proc isPlainDirectory(path: string): bool =
  try:
    getFileInfo(path, followSymlink = false).kind == pcDir
  except OSError:
    false

# ---------------------------------------------------------------------------
# Privacy: the Windows form of `chmod 700`
# ---------------------------------------------------------------------------

proc requirePrivate(cfg: Config; dir, description: string) =
  ## Owned by this account (or Administrators, which is what an elevated
  ## token makes), with a DACL granting access to nobody but this account,
  ## SYSTEM and Administrators. The owner-only rule of `docs/database.md`'s
  ## host-state-directory table, strengthened from "write" to "any access",
  ## which is what POSIX `0700` says.
  let facts = readDirectorySecurity(dir)
  if facts.errorCode != 0:
    refuse(description & " cannot be inspected (Windows error " &
      $facts.errorCode & "): " & dir)
  if (facts.attributes and 0x400'u32) != 0 or
      (facts.attributes and 0x10'u32) == 0:
    refuse(description & " is not a plain directory: " & dir)
  if facts.ownerSid notin [cfg.ownerSid, administratorsSid]:
    refuse(description & " is owned by " & facts.ownerSid &
      ", not by this account (" & cfg.ownerSid & "): " & dir)
  if not facts.daclPresent:
    refuse(description & " has a NULL DACL: " & dir)
  for ace in facts.aces:
    if ace.aceType in [1, 6, 10, 12]:
      continue
    if not ace.sidKnown or ace.aceType notin [0, 5, 9, 11]:
      refuse(description & " carries an ACE this gate cannot read: " & dir)
    if ace.sid notin [cfg.ownerSid, systemSid, administratorsSid]:
      refuse(description & " grants " & ace.sid & " access; it must be " &
        "private to " & cfg.ownerSid & ": " & dir)

proc systemTool(name: string): string =
  result = getEnv("SYSTEMROOT", r"C:\Windows") / "System32" / name
  if not fileExists(result):
    refuse("no Windows system tool " & result)

# ---------------------------------------------------------------------------
# Processes
# ---------------------------------------------------------------------------

proc runLogged(exe: string; args: openArray[string]; log: string;
               env: StringTableRef = nil; cwd = ""): int =
  ## Runs ``exe`` with ``args`` exactly as given, its output (stderr folded
  ## in) captured to ``log``, and answers its exit code. Line-by-line reading
  ## to the process's exit, as `execCmdEx` does: `outputStream.readAll`
  ## returned only the first chunk of a Windows pipe in this tree's
  ## measurements.
  var output = ""
  try:
    let process = startProcess(exe, workingDir = cwd, args = args, env = env,
      options = {poStdErrToStdOut})
    let stream = process.outputStream
    var line = newStringOfCap(256)
    while true:
      if stream.readLine(line):
        output.add(line)
        output.add('\n')
      else:
        result = process.peekExitCode()
        if result != -1:
          break
    result = process.waitForExit()
    process.close()
  except OSError as error:
    output.add("cannot start " & exe & ": " & error.msg & "\n")
    result = 127
  writeFile(log, output)

proc icacls(path: string; args: openArray[string]) =
  var all = @[path]
  for arg in args:
    all.add(arg)
  let log = getTempDir() / "rq-gate-icacls.log"
  if runLogged(systemTool("icacls.exe"), all, log) != 0:
    refuse("icacls " & all.join(" ") & " failed: " & readFile(log))

proc nimExe(cfg: Config): string =
  cfg.nimRoot / "bin" / "nim.exe"

proc pinnedEnv(cfg: Config; home, tmp, xdg: string): StringTableRef =
  ## `env -i` plus exactly what a Windows compile needs: the verified
  ## toolchain's PATH, SYSTEMROOT, and PRIVATE home, temp and configuration
  ## directories -- Nim reads its user configuration from %APPDATA%, and gcc
  ## writes its temporaries to %TEMP%.
  result = newStringTable(modeCaseInsensitive)
  result["SYSTEMROOT"] = getEnv("SYSTEMROOT", r"C:\Windows")
  result["PATH"] = cfg.nimRoot / "bin" & PathSep & cfg.gccBin & PathSep &
    getEnv("SYSTEMROOT", r"C:\Windows") / "System32"
  result["HOME"] = home
  result["USERPROFILE"] = home
  result["APPDATA"] = xdg
  result["LOCALAPPDATA"] = xdg
  result["XDG_CONFIG_HOME"] = xdg
  result["TEMP"] = tmp
  result["TMP"] = tmp
  result["TMPDIR"] = tmp
  result["LC_ALL"] = "C"
  result["LANG"] = "C"

# ---------------------------------------------------------------------------
# The source authority: the snapshot IS the recorded tree
# ---------------------------------------------------------------------------

proc verifySource(cfg: Config; snapshot, index, log: string) =
  ## Re-hashes ``snapshot`` into a private index seeded from the recorded
  ## tree, and refuses unless the tree git writes is the recorded tree.
  ## Seeding keeps every path outside the snapshot's subset as recorded, and
  ## keeps file modes as recorded where Windows cannot see an executable
  ## bit; `add -A -f` then records every modification, addition and deletion
  ## under the subset, ignored or not.
  let env = newStringTable(modeCaseInsensitive)
  env["SYSTEMROOT"] = getEnv("SYSTEMROOT", r"C:\Windows")
  env["PATH"] = getEnv("PATH")
  env["GIT_INDEX_FILE"] = index
  env["HOME"] = cfg.work / "private" / "home"
  env["GIT_CONFIG_NOSYSTEM"] = "1"
  env["GIT_CONFIG_GLOBAL"] = cfg.work / "private" / "gitconfig"
  if fileExists(index):
    removeFile(index)
  writeFile(cfg.work / "private" / "gitconfig", "")
  let base = @["--git-dir=" & cfg.gitCommonDir, "--work-tree=" & snapshot,
    "-c", "core.autocrlf=false", "-c", "core.safecrlf=false",
    "-c", "core.filemode=false", "-c", "safe.directory=*"]
  if runLogged(cfg.git, base & @["read-tree", cfg.sourceTree], log, env) != 0:
    refuse("git read-tree " & cfg.sourceTree & " failed: " & readFile(log))
  if runLogged(cfg.git, base & @["add", "-A", "-f", "--"] & @sourcePaths,
      log, env) != 0:
    refuse("git add over the snapshot failed: " & readFile(log))
  if runLogged(cfg.git, base & @["write-tree"], log, env) != 0:
    refuse("git write-tree failed: " & readFile(log))
  let written = readFile(log).strip()
  if written != cfg.sourceTree:
    refuse("the source snapshot " & snapshot & " is tree " & written &
      ", not the recorded " & cfg.sourceTree &
      ": something changed it after it was materialised")

# ---------------------------------------------------------------------------
# The dependency-manifest validator (validate_nim_scanner_deps.sh)
# ---------------------------------------------------------------------------

proc validateScannerDeps(cfg: Config; depsArgument, sourceArgument,
                         nimRootArgument: string) =
  ## The scanner's compiler-reported closure is the copied scanner source,
  ## the verified compiler's `compiler/` (including the six lexer modules it
  ## cannot be built without) and its `lib/`, and nothing else.
  proc existing(path, description: string): string =
    if path.len == 0:
      refuse(description & " must not be empty")
    if not path.isAbsolute:
      refuse(description & " is not absolute: " & path)
    if path != expandFilename(path):
      refuse(description & " is not canonical: " & path)
    if not (fileExists(path) or dirExists(path)):
      refuse(description & " does not exist: " & path)
    result = finalPath(path)
    if not samePath(result, path):
      refuse(description & " is not canonical: " & path & " (final: " &
        result & ")")

  let deps = existing(depsArgument, "compiler dependency manifest")
  let source = existing(sourceArgument, "copied scanner source")
  let nimRoot = existing(nimRootArgument, "Nim compiler root")
  if not isRegularFile(deps):
    refuse("compiler dependency manifest is not a regular non-symlink file: " &
      deps)
  var manifest = ""
  try:
    manifest = readFile(deps)
  except IOError:
    refuse("compiler dependency manifest is not readable: " & deps)
  if manifest.len == 0:
    refuse("compiler dependency manifest is empty: " & deps)
  if not isRegularFile(source):
    refuse("copied scanner source is not a regular non-symlink file: " & source)
  if not isPlainDirectory(nimRoot):
    refuse("Nim compiler root is not a non-symlink directory: " & nimRoot)
  if not samePath(nimRoot, finalPath(cfg.nimRoot)):
    refuse("Nim compiler root is not the verified tool-store extraction: " &
      nimRoot)
  let compilerRoot = existing(nimRoot / "compiler", "Nim compiler source root")
  let libRoot = existing(nimRoot / "lib", "Nim standard-library root")
  if not isPlainDirectory(compilerRoot) or not isPlainDirectory(libRoot):
    refuse("Nim compiler or library root is not a non-symlink directory: " &
      nimRoot)
  if '\0' in manifest or '\r' in manifest:
    refuse("compiler dependency manifest contains a NUL or carriage-return byte")

  var requiredSeen = initHashSet[string]()
  var seen = initHashSet[string]()
  var sourceSeen = false
  var count = 0
  var lines = manifest.split('\n')
  if lines.len > 0 and lines[^1].len == 0:
    lines.setLen(lines.len - 1)
  for dependency in lines:
    inc count
    if dependency.len == 0:
      refuse("compiler dependency manifest contains a blank path")
    if not dependency.isAbsolute:
      refuse("compiler dependency path is not absolute: " & dependency)
    if not isRegularFile(dependency):
      refuse("compiler dependency is not a regular non-symlink file: " &
        dependency)
    if dependency != expandFilename(dependency):
      refuse("compiler dependency path is not canonical: " & dependency)
    let canonical = finalPath(dependency)
    if not samePath(canonical, dependency):
      refuse("compiler dependency path is not canonical: " & dependency &
        " (final: " & canonical & ")")
    let key = canonical.toLowerAscii
    if key in seen:
      refuse("compiler dependency manifest contains a duplicate: " & canonical)
    seen.incl key
    if samePath(canonical, source):
      sourceSeen = true
      continue
    if canonical.isWithin(compilerRoot):
      let relative = canonical[compilerRoot.len + 1 .. ^1]
      for module in requiredCompilerModules:
        if samePath(relative, module):
          requiredSeen.incl module
    elif not canonical.isWithin(libRoot):
      refuse("compiler dependency is outside the copied source and exact " &
        "Nim roots: " & canonical)
  if count == 0:
    refuse("compiler dependency manifest contains no paths")
  if not sourceSeen:
    refuse("compiler dependency manifest does not contain the copied " &
      "scanner source: " & source)
  for module in requiredCompilerModules:
    if not isRegularFile(compilerRoot / module):
      refuse("required compiler module is not a regular non-symlink file: " &
        compilerRoot / module)
    if module notin requiredSeen:
      refuse("compiler dependency manifest is missing required compiler " &
        "module: " & compilerRoot / module)

# ---------------------------------------------------------------------------
# The scanner bootstrap (bootstrap_nim_ref_token_scanner.sh)
# ---------------------------------------------------------------------------

proc bootstrapScanner(cfg: Config; pinnedNim, scannerSource, output,
                      bootstrapRootArgument: string): string =
  ## Builds the ref scanner from a PRIVATE COPY of ``scannerSource`` with the
  ## verified compiler, and answers the Nim root it was bound to. The copy is
  ## what defeats a compiler shadow: `import compiler/lexer` resolves against
  ## the importing module's own directory first, and the copy's directory
  ## holds nothing but it.
  if pinnedNim.len == 0:
    refuse("pinned Nim must not be empty")
  if not fileExists(pinnedNim) or
      not samePath(finalPath(pinnedNim), finalPath(cfg.nimExe)):
    refuse("pinned Nim is not the verified tool-store compiler: " & pinnedNim)
  if not isRegularFile(scannerSource):
    refuse("scanner source is not a regular non-symlink file: " &
      scannerSource)
  if output.len == 0:
    refuse("scanner output must not be empty")
  if bootstrapRootArgument.len == 0:
    refuse("private bootstrap root must not be empty")
  if not isPlainDirectory(bootstrapRootArgument):
    refuse("private bootstrap root is not a non-symlink directory: " &
      bootstrapRootArgument)
  let bootstrapRoot = finalPath(bootstrapRootArgument)
  for _ in walkDir(bootstrapRoot):
    refuse("private bootstrap root is not empty: " & bootstrapRoot)
  requirePrivate(cfg, bootstrapRoot, "private bootstrap root")

  let home = bootstrapRoot / "home"
  let tmp = bootstrapRoot / "tmp"
  let xdg = bootstrapRoot / "xdg"
  let nimcache = bootstrapRoot / "nimcache"
  for dir in [home, tmp, xdg, nimcache]:
    createDir(dir)
  let copied = bootstrapRoot / "nim_ref_token_scanner.nim"
  copyFile(scannerSource, copied)
  let candidate = bootstrapRoot / "nim_ref_token_scanner.exe"
  let deps = nimcache / "nim_ref_token_scanner.deps"
  let env = pinnedEnv(cfg, home, tmp, xdg)
  let log = bootstrapRoot / "bootstrap.log"

  let dumpLog = bootstrapRoot / "nim-dump.json"
  if runLogged(pinnedNim, ["dump", "--dump.format:json", "--skipCfg:on",
      "--skipUserCfg:on", "--skipParentCfg:on", "--skipProjCfg:on", copied],
      dumpLog, env, bootstrapRoot) != 0:
    refuse("the pinned Nim could not report its root: " & readFile(dumpLog))
  let dump = readFile(dumpLog)
  if dump.count("\"prefixdir\":") != 1:
    refuse("the pinned Nim reported no single prefix directory")
  var nimRoot = ""
  for line in dump.splitLines:
    if line.strip.startsWith("{"):
      try:
        nimRoot = parseJson(line)["prefixdir"].getStr()
      except CatchableError:
        discard
  if nimRoot.len == 0:
    refuse("the pinned Nim did not report its root")
  if not samePath(finalPath(nimRoot), finalPath(cfg.nimRoot)):
    refuse("the pinned Nim reported root " & nimRoot &
      ", not the verified extraction " & cfg.nimRoot)
  if not isPlainDirectory(nimRoot / "compiler") or
      not isRegularFile(nimRoot / "compiler" / "lexer.nim") or
      not isPlainDirectory(nimRoot / "lib"):
    refuse("the reported Nim root lacks exact compiler and library sources: " &
      nimRoot)

  let arguments = @["c", "--skipCfg:on", "--skipUserCfg:on",
    "--skipParentCfg:on", "--skipProjCfg:on", "--cc:gcc", "--mm:arc",
    "--hints:off", "--warnings:off", "--path:" & nimRoot,
    "--nimcache:" & nimcache, "--out:" & candidate]
  if runLogged(pinnedNim, arguments & @["--genScript:on", copied], log, env,
      bootstrapRoot) != 0:
    refuse("the scanner's dependency-manifest compile failed: " &
      readFile(log))
  if not fileExists(deps):
    refuse("the pinned Nim did not emit the scanner dependency manifest: " &
      deps)
  validateScannerDeps(cfg, deps, copied, nimRoot)
  if runLogged(pinnedNim, arguments & @[copied], log, env,
      bootstrapRoot) != 0:
    refuse("the scanner compile failed: " & readFile(log))
  if not fileExists(candidate) or getFileSize(candidate) == 0:
    refuse("the pinned Nim did not build an executable scanner")
  createDir(output.parentDir)
  copyFile(candidate, output)
  nimRoot

# ---------------------------------------------------------------------------
# The regression suite (test_nim_ref_token_scanner.sh)
# ---------------------------------------------------------------------------

type Suite = object
  cfg: Config
  work: string
  index: int
  lastLog: string
  lastDeps: string

proc failCase(suite: Suite; message: string) {.noreturn.} =
  var text = "Nim ref token scanner regression failure: " & message
  if suite.lastLog.len > 0 and fileExists(suite.lastLog):
    let lines = readFile(suite.lastLog).splitLines
    text.add("\n" & lines[0 ..< min(lines.len, 120)].join("\n"))
  refuse(text)

proc nextLog(suite: var Suite; kind: string): string =
  inc suite.index
  suite.lastLog = suite.work / ($suite.index & "-" & kind & ".log")
  suite.lastLog

proc inProcess(log: string; body: proc ()): int =
  ## An in-process check, run the way the Nix suite runs its scripts: a
  ## refusal is a non-zero exit, and its message is the log.
  try:
    body()
    writeFile(log, "")
    0
  except GateError, OSError, IOError, ValueError:
    writeFile(log, getCurrentExceptionMsg() & "\n")
    1

proc expectSuccess(suite: var Suite; description: string;
                   body: proc (log: string): int) =
  let log = suite.nextLog("success")
  if body(log) != 0:
    suite.failCase(description & " unexpectedly failed")

proc expectFailure(suite: var Suite; description: string;
                   body: proc (log: string): int) =
  let log = suite.nextLog("failure")
  if body(log) == 0:
    suite.failCase(description & " unexpectedly succeeded")

proc logHas(suite: Suite; text: string): bool =
  text in readFile(suite.lastLog)

proc assertFindings(suite: Suite; expected: int; path: string;
                    lines: openArray[string]) =
  let actual = readFile(suite.lastLog).count(refFinding)
  if actual != expected:
    suite.failCase("expected " & $expected & " ref findings, found " & $actual)
  for line in lines:
    if not suite.logHas(path & ":" & line & ":"):
      suite.failCase("missing exact ref finding " & path & ":" & line)

proc makeUnreadable(cfg: Config; path: string) =
  icacls(path, ["/deny", "*" & cfg.ownerSid & ":(R)"])

proc makeReadable(cfg: Config; path: string) =
  icacls(path, ["/remove:d", "*" & cfg.ownerSid])

proc link(suite: Suite; target, linkPath: string) =
  ## A NATIVE symbolic link. Windows grants the right to create one to an
  ## elevated token or to Developer Mode; without it the suite cannot ask
  ## the questions its link cases ask, and says so rather than skipping them.
  try:
    createSymlink(target, linkPath)
  except OSError as error:
    suite.failCase("cannot create the symbolic link " & linkPath & " -> " &
      target & " (" & error.msg & "): the gate's link cases need " &
      "SeCreateSymbolicLinkPrivilege -- run it elevated, or enable " &
      "Developer Mode")
  if not isLink(linkPath):
    suite.failCase("created " & linkPath & " but it is not a symbolic link")

proc runSelfTest(cfg: Config; scanner, nimRoot, bootstrapRoot: string) =
  var suite = Suite(cfg: cfg, work: cfg.work / "test-work")
  createDir(suite.work)
  let work = finalPath(suite.work)
  suite.work = work
  let fixtures = cfg.snapshot / "tests" / "fixtures" /
    "static-helper-ref-scanner"
  let scannerSource = cfg.snapshot / "scripts" / "nim_ref_token_scanner.nim"
  let nimLibRoot = nimRoot / "lib"
  let home = work / "compiler-home"
  let tmp = work / "compiler-tmp"
  let xdg = work / "compiler-xdg"
  for dir in [home, tmp, xdg]:
    createDir(dir)
  let env = pinnedEnv(cfg, home, tmp, xdg)

  proc run(exe: string; args: seq[string]; cwd = "";
           runEnv: StringTableRef = nil): proc (log: string): int =
    let exeCopy = exe
    let argsCopy = args
    let cwdCopy = cwd
    let envCopy = runEnv
    result = proc (log: string): int =
      runLogged(exeCopy, argsCopy, log, envCopy, cwdCopy)

  let nimArguments = @["--skipCfg:on", "--skipUserCfg:on",
    "--skipParentCfg:on", "--skipProjCfg:on", "--cc:gcc", "--mm:arc",
    "--hints:off", "--warnings:off"]

  proc compileFixture(suite: var Suite; path: string) =
    let name = path.splitFile.name
    suite.expectSuccess("Nim compilation of " & name,
      run(cfg.nimExe, @["c"] & nimArguments & @[
        "--nimcache:" & work / ("fixture-cache-" & name),
        "--out:" & work / ("fixture-" & name & ".exe"), path], runEnv = env))

  proc compileClosureEntry(suite: var Suite; caseName, entry: string;
                           extra: seq[string] = @[]) =
    let cache = work / ("closure-cache-" & caseName)
    removeDir(cache)
    let archive = work / (caseName & ".a")
    let arguments = @["c"] & nimArguments & @["--app:staticlib",
      "--nimcache:" & cache, "--out:" & archive] & extra
    suite.expectSuccess("Nim dependency-manifest compilation for " & caseName,
      run(cfg.nimExe, arguments & @["--genScript:on", entry], runEnv = env))
    suite.lastDeps = cache / (entry.splitFile.name & ".deps")
    if not fileExists(suite.lastDeps):
      suite.failCase("Nim did not emit dependency manifest for " & caseName)
    suite.expectSuccess("full ARC static-library compilation for " & caseName,
      run(cfg.nimExe, arguments & @[entry], runEnv = env))
    if not fileExists(archive) or getFileSize(archive) == 0:
      suite.failCase("Nim did not build the static archive for " & caseName)

  proc validator(deps, source, root: string): proc (log: string): int =
    result = proc (log: string): int =
      inProcess(log, proc () = validateScannerDeps(cfg, deps, source, root))

  proc closure(repo, trusted, entry, deps: string): proc (log: string): int =
    run(scanner, @["closure", repo, trusted, entry, deps])

  # -- The tool-store AUTHORITY -------------------------------------------
  #
  # The Nix suite proves its generated wrapper reports the authority it was
  # built with, even under a hostile environment. The tool-store authority is
  # established by the front script, so it is the front that is re-run: the
  # authority it reports must be the one this run was given, a hostile
  # environment must not change that answer, and every way of pointing it at
  # a toolchain with another identity must be a refusal.
  let expectedAuthority = readFile(cfg.authorityFile).strip()
  let frontEnv = newStringTable(modeCaseInsensitive)
  frontEnv["SYSTEMROOT"] = getEnv("SYSTEMROOT", r"C:\Windows")
  frontEnv["PATH"] = cfg.callerPath
  frontEnv["TEMP"] = tmp
  frontEnv["TMP"] = tmp
  let front = @[cfg.front, "--print-authority"]
  suite.expectSuccess("tool-store authority introspection",
    run(cfg.bash, front, cfg.repo, frontEnv))
  if readFile(suite.lastLog).strip() != expectedAuthority:
    suite.failCase("the front reported an authority other than this run's")

  let hostileConfig = work / "hostile-config"
  createDir(hostileConfig)
  let hostileEnv = newStringTable(modeCaseInsensitive)
  for key, value in frontEnv:
    hostileEnv[key] = value
  for key in ["HOME", "XDG_CONFIG_HOME", "XDG_CONFIG_DIRS", "NIMBLE_DIR",
      "NIM_LIB_PREFIX", "NIM_CONFIG_DIR", "REPROBUILD_SRC", "APPDATA",
      "LOCALAPPDATA", "USERPROFILE"]:
    hostileEnv[key] = hostileConfig
  hostileEnv["RUNQUOTA_PINNED_NIM"] = systemTool("cmd.exe")
  hostileEnv["RUNQUOTA_SOURCE_ROOT"] = work / "mutable-source"
  hostileEnv["CC"] = systemTool("cmd.exe")
  hostileEnv["CXX"] = systemTool("cmd.exe")
  suite.expectSuccess("tool-store authority introspection under a hostile " &
    "environment", run(cfg.bash, front, cfg.repo, hostileEnv))
  if readFile(suite.lastLog).strip() != expectedAuthority:
    suite.failCase("a hostile environment redirected the tool-store authority")

  let nimPin = block:
    var found = ""
    for line in expectedAuthority.splitLines:
      if line.startsWith("nim="):
        found = line["nim=".len .. ^1]
    found
  let nimSha = nimPin[nimPin.rfind(":") + 1 .. ^1]

  proc fakePrefix(name, lockIdentity, archiveBytes: string;
                  receipt = true): string =
    ## A tool-store-shaped tree -- prefixes/nim/<id>/bin/nim.exe, a receipt,
    ## a download cache -- whose every part can be made to lie.
    let store = work / name / "tool-store"
    let prefix = store / "prefixes" / "nim" / (nimSha[0 .. 15] & "-fake")
    createDir(prefix / "bin")
    writeFile(prefix / "bin" / "nim.exe", "not a compiler")
    if receipt:
      writeFile(prefix / ".reprobuild-tarball-receipt.json", "{\n" &
        "  \"installMethod\": \"tarball\",\n" &
        "  \"packageSelector\": \"nim\",\n" &
        "  \"stripComponents\": 1,\n" &
        "  \"lockIdentity\": \"" & lockIdentity & "\"\n}\n")
    createDir(store / "downloads")
    writeFile(store / "downloads" / (nimSha & ".archive"), archiveBytes)
    prefix / "bin"

  proc withPathFirst(dir: string): StringTableRef =
    result = newStringTable(modeCaseInsensitive)
    for key, value in frontEnv:
      result[key] = value
    result["PATH"] = dir & PathSep & cfg.callerPath

  let tamperedBin = fakePrefix("tampered-archive", nimPin,
    "these are not the pinned bytes")
  suite.expectFailure("a prefix claiming the pinned Nim over an archive " &
    "that is not the pinned bytes",
    run(cfg.bash, front, cfg.repo, withPathFirst(tamperedBin)))
  if not suite.logHas("not the pinned"):
    suite.failCase("the tampered archive was not refused for its hash")

  let unpinnedBin = fakePrefix("unpinned-identity",
    "tarball:nim@0.0.0:sha256:" & repeat('0', 64), "")
  suite.expectFailure("a prefix whose receipt names an unpinned Nim",
    run(cfg.bash, front, cfg.repo, withPathFirst(unpinnedBin)))
  if not suite.logHas("the gate is pinned to"):
    suite.failCase("the unpinned Nim was not refused for its identity")

  let bareBin = fakePrefix("no-receipt", nimPin, "", receipt = false)
  suite.expectFailure("a Nim outside any tool-store prefix",
    run(cfg.bash, front, cfg.repo, withPathFirst(bareBin)))
  if not suite.logHas("is not in a reprobuild tool-store prefix"):
    suite.failCase("the receipt-less Nim was not refused as unprovisioned")

  # The Nix suite's "mutable source root" refusal: a copy of the snapshot
  # that differs from the recorded tree by one byte is refused.
  let mutableSource = work / "mutable-source"
  for path in sourcePaths:
    copyDir(cfg.snapshot / path, mutableSource / path)
  let mutated = mutableSource / "libs" / "static_helpers.txt"
  setFilePermissions(mutated, {fpUserRead, fpUserWrite})
  writeFile(mutated, readFile(mutated) & "# one more line\n")
  suite.expectFailure("the source authority's refusal of a modified snapshot",
    proc (log: string): int =
      inProcess(log, proc () =
        verifySource(cfg, mutableSource, work / "mutable.index",
          work / "mutable-git.log")))
  if not suite.logHas("not the recorded"):
    suite.failCase("the modified snapshot was not refused for its tree")

  # -- The bootstrap's manifest AUTHORITY ---------------------------------
  let bootstrapSource = bootstrapRoot / "nim_ref_token_scanner.nim"
  let bootstrapDeps = bootstrapRoot / "nimcache" / "nim_ref_token_scanner.deps"
  suite.expectSuccess("primary scanner bootstrap dependency authority",
    validator(bootstrapDeps, bootstrapSource, nimRoot))
  let bootstrapLines = readFile(bootstrapDeps).splitLines
  for expected in [bootstrapSource, nimRoot / "compiler" / "idents.nim",
      nimRoot / "compiler" / "lexer.nim",
      nimRoot / "compiler" / "lineinfos.nim",
      nimRoot / "compiler" / "llstream.nim",
      nimRoot / "compiler" / "options.nim",
      nimRoot / "compiler" / "pathutils.nim"]:
    var present = false
    for line in bootstrapLines:
      if samePath(line, expected):
        present = true
    if not present:
      suite.failCase("primary scanner manifest lacks exact authority " &
        expected)
  for line in bootstrapLines:
    if line.len > 0 and line.isWithin(finalPath(cfg.snapshot)):
      suite.failCase("primary scanner manifest contains a repository " &
        "dependency: " & line)

  proc variant(name, content: string): string =
    result = work / name
    writeFile(result, content)

  let bootstrapText = readFile(bootstrapDeps)
  suite.expectFailure("missing scanner bootstrap dependency manifest",
    validator(work / "missing-bootstrap.deps", bootstrapSource, nimRoot))
  suite.expectFailure("empty scanner bootstrap dependency manifest",
    validator(variant("empty-bootstrap.deps", ""), bootstrapSource, nimRoot))
  let unreadableBootstrap = variant("unreadable-bootstrap.deps", bootstrapText)
  makeUnreadable(cfg, unreadableBootstrap)
  suite.expectFailure("unreadable scanner bootstrap dependency manifest",
    validator(unreadableBootstrap, bootstrapSource, nimRoot))
  makeReadable(cfg, unreadableBootstrap)
  suite.expectFailure("duplicate scanner bootstrap dependency",
    validator(variant("duplicate-bootstrap.deps",
      bootstrapText & bootstrapSource & "\n"), bootstrapSource, nimRoot))

  proc without(text, dropped: string): string =
    var kept: seq[string] = @[]
    for line in text.splitLines:
      if line.len > 0 and not samePath(line, dropped):
        kept.add(line)
    kept.join("\n") & "\n"

  suite.expectFailure("scanner bootstrap manifest missing copied source",
    validator(variant("missing-source-bootstrap.deps",
      without(bootstrapText, bootstrapSource)), bootstrapSource, nimRoot))
  suite.expectFailure("scanner bootstrap manifest missing exact compiler " &
    "lexer", validator(variant("missing-lexer-bootstrap.deps",
      without(bootstrapText, nimRoot / "compiler" / "lexer.nim")),
      bootstrapSource, nimRoot))
  suite.expectFailure("blank scanner bootstrap dependency path",
    validator(variant("blank-bootstrap.deps", bootstrapText & "\n"),
      bootstrapSource, nimRoot))
  suite.expectFailure("NUL scanner bootstrap dependency manifest",
    validator(variant("nul-bootstrap.deps", bootstrapText & "\0"),
      bootstrapSource, nimRoot))
  suite.expectFailure("CRLF scanner bootstrap dependency manifest",
    validator(variant("crlf-bootstrap.deps",
      bootstrapText.replace("\n", "\r\n")), bootstrapSource, nimRoot))
  suite.expectFailure("repository-local scanner bootstrap dependency",
    validator(variant("local-bootstrap.deps",
      bootstrapText & scannerSource & "\n"), bootstrapSource, nimRoot))
  suite.expectFailure("scanner bootstrap dependency from another root of " &
    "the compiler's package", validator(variant("other-root-bootstrap.deps",
      bootstrapText & cfg.nimExe & "\n"), bootstrapSource, nimRoot))
  suite.expectFailure("relative scanner bootstrap dependency",
    validator(variant("relative-bootstrap.deps",
      bootstrapText & "compiler" & DirSep & "lexer.nim\n"),
      bootstrapSource, nimRoot))
  suite.expectFailure("noncanonical scanner bootstrap dependency",
    validator(variant("noncanonical-bootstrap.deps", bootstrapText &
      bootstrapRoot & DirSep & "nimcache" & DirSep & ".." & DirSep &
      "nim_ref_token_scanner.nim\n"), bootstrapSource, nimRoot))
  let bootstrapLink = work / "bootstrap-source-link.nim"
  suite.link(bootstrapSource, bootstrapLink)
  suite.expectFailure("symlink scanner bootstrap dependency",
    validator(variant("symlink-bootstrap.deps",
      bootstrapText & bootstrapLink & "\n"), bootstrapSource, nimRoot))
  suite.expectFailure("missing scanner bootstrap dependency",
    validator(variant("missing-dependency-bootstrap.deps",
      bootstrapText & work / "missing-bootstrap-source.nim" & "\n"),
      bootstrapSource, nimRoot))

  proc privateRoot(name: string): string =
    result = work / name
    createDir(result)
    requirePrivate(cfg, result, name)

  let missingPinnedRoot = privateRoot("missing-pinned-bootstrap")
  let wrongWrapperRoot = privateRoot("wrong-wrapper-bootstrap")
  suite.expectFailure("scanner bootstrap without a pinned Nim",
    proc (log: string): int =
      inProcess(log, proc () =
        discard bootstrapScanner(cfg, "", scannerSource,
          work / "unset-wrapper-scanner.exe", missingPinnedRoot)))
  suite.expectFailure("scanner bootstrap with a Nim that is not the " &
    "verified extraction", proc (log: string): int =
      inProcess(log, proc () =
        discard bootstrapScanner(cfg, systemTool("cmd.exe"), scannerSource,
          work / "wrong-wrapper-scanner.exe", wrongWrapperRoot)))

  # -- The LEXER: compiler-valid ref syntax, every spelling ---------------
  let accepted = fixtures / "accepted.nim"
  let rejected = fixtures / "rejected.nim"
  let styleRef = fixtures / "style_ref.nim"
  let mixedCaseRef = fixtures / "mixed_case_ref.nim"
  let rawRef = fixtures / "raw_trailing_backslash_ref.nim"
  let generalizedRef = fixtures / "generalized_trailing_backslash_ref.nim"
  let numericRef = fixtures / "numeric_suffix_ref.nim"
  let malformedString = work / "malformed_string.nim"
  let malformedComment = work / "malformed_comment.nim"
  copyFile(fixtures / "malformed_string.nim.fixture", malformedString)
  copyFile(fixtures / "malformed_comment.nim.fixture", malformedComment)

  suite.compileFixture(accepted)
  suite.expectSuccess("comments, literals, ordinary identifiers, and " &
    "backticked ref", run(scanner, @["scan", "--", accepted]))

  for (source, lines) in [(rejected, @["4", "10"]), (styleRef, @["2"]),
      (mixedCaseRef, @["2"]), (rawRef, @["3"]), (generalizedRef, @["6"]),
      (numericRef, @["3"])]:
    suite.compileFixture(source)
    suite.expectFailure("compiler-valid ref syntax in " &
      source.extractFilename, run(scanner, @["scan", "--", source]))
    suite.assertFindings(lines.len, source, lines)

  # -- The COMPILER SHADOW: why the bootstrap copies its source -----------
  let hostileProject = work / "hostile-project"
  let hostileScripts = hostileProject / "scripts"
  let hostileCompiler = hostileScripts / "compiler"
  createDir(hostileCompiler)
  copyFile(scannerSource, hostileScripts / "nim_ref_token_scanner.nim")
  copyDir(nimRoot / "compiler", hostileCompiler)
  const identLine =
    "    result.getIdent($s, hashIgnoreStyle($s)).id = ord(s)"
  let idents = readFile(hostileCompiler / "idents.nim")
  if idents.count(identLine & "\n") + idents.count(identLine & "\r\n") != 1:
    suite.failCase("the compiler's idents.nim no longer has the one line " &
      "the shadow reproduction rewrites")
  writeFile(hostileCompiler / "idents.nim", idents.multiReplace(
    (identLine & "\r\n", "    if s != wRef:\r\n  " & identLine & "\r\n"),
    (identLine & "\n", "    if s != wRef:\n  " & identLine & "\n")))
  let hostileUnisolated = work / "hostile-unisolated-scanner.exe"
  let hostileHome = work / "hostile-home"
  let hostileTmp = work / "hostile-tmp"
  let hostileXdg = work / "hostile-xdg"
  for dir in [hostileHome, hostileTmp, hostileXdg]:
    createDir(dir)
  suite.expectSuccess("unisolated scanner compilation under reviewer " &
    "compiler shadow", run(cfg.nimExe, @["c"] & nimArguments & @[
      "--path:" & nimRoot,
      "--nimcache:" & work / "hostile-unisolated-cache",
      "--out:" & hostileUnisolated,
      hostileScripts / "nim_ref_token_scanner.nim"],
      runEnv = pinnedEnv(cfg, hostileHome, hostileTmp, hostileXdg)))
  suite.expectSuccess("reviewer compiler shadow evasion reproduction",
    run(hostileUnisolated, @["scan", "--", styleRef]))

  let hostileBootstrap = privateRoot("hostile-bootstrap")
  let hostileHardened = work / "hostile-hardened-scanner.exe"
  # The hostile ENVIRONMENT, in this process: nothing the bootstrap starts
  # may inherit it.
  let hostileKeys = ["RUNQUOTA_PINNED_NIM", "RUNQUOTA_SOURCE_ROOT", "HOME",
    "XDG_CONFIG_HOME", "XDG_CONFIG_DIRS", "NIMBLE_DIR", "NIM_LIB_PREFIX",
    "NIM_CONFIG_DIR", "CC", "CXX", "APPDATA"]
  var saved: seq[(string, string, bool)] = @[]
  for key in hostileKeys:
    saved.add((key, getEnv(key), existsEnv(key)))
  putEnv("RUNQUOTA_PINNED_NIM", systemTool("cmd.exe"))
  putEnv("RUNQUOTA_SOURCE_ROOT", hostileProject)
  putEnv("HOME", hostileProject)
  putEnv("XDG_CONFIG_HOME", hostileProject / "xdg")
  putEnv("XDG_CONFIG_DIRS", hostileProject / "xdg")
  putEnv("NIMBLE_DIR", hostileProject / "nimble")
  putEnv("NIM_LIB_PREFIX", hostileCompiler)
  putEnv("NIM_CONFIG_DIR", hostileProject / "nim-config")
  putEnv("CC", systemTool("cmd.exe"))
  putEnv("CXX", systemTool("cmd.exe"))
  putEnv("APPDATA", hostileProject)
  var hostileReport = ""
  let hostileLog = suite.nextLog("hostile-bootstrap")
  let hostileStatus = inProcess(hostileLog, proc () =
    hostileReport = bootstrapScanner(cfg, cfg.nimExe,
      hostileScripts / "nim_ref_token_scanner.nim", hostileHardened,
      hostileBootstrap))
  for (key, value, present) in saved:
    if present: putEnv(key, value) else: delEnv(key)
  if hostileStatus != 0:
    suite.failCase("isolated scanner bootstrap under reviewer compiler " &
      "shadow failed")
  if not samePath(hostileReport, nimRoot):
    suite.failCase("hostile bootstrap reported an unexpected Nim root: " &
      hostileReport)
  suite.expectFailure("isolated scanner rejects compile-proven ref despite " &
    "reviewer compiler shadow", run(hostileHardened, @["scan", "--", styleRef]))
  suite.assertFindings(1, styleRef, ["2"])
  let hostileDeps = hostileBootstrap / "nimcache" / "nim_ref_token_scanner.deps"
  suite.expectSuccess("hostile bootstrap dependency authority",
    validator(hostileDeps, hostileBootstrap / "nim_ref_token_scanner.nim",
      nimRoot))
  var boundIdents = false
  for line in readFile(hostileDeps).splitLines:
    if samePath(line, nimRoot / "compiler" / "idents.nim"):
      boundIdents = true
    if line.len > 0 and line.isWithin(finalPath(hostileCompiler)):
      suite.failCase("hostile bootstrap manifest contains reviewer-" &
        "controlled compiler sources")
  if not boundIdents:
    suite.failCase("hostile bootstrap did not bind exact immutable " &
      "compiler idents")

  # -- The scanner's own contract -----------------------------------------
  suite.expectFailure("multi-file aggregation with compiler-valid ref types",
    run(scanner, @["scan", "--", accepted, styleRef, mixedCaseRef, rawRef,
      generalizedRef, numericRef, rejected]))
  if readFile(suite.lastLog).count(refFinding) != 7:
    suite.failCase("multi-file scan must report all seven ref tokens")
  for finding in [styleRef & ":2:", mixedCaseRef & ":2:", rawRef & ":3:",
      generalizedRef & ":6:", numericRef & ":3:", rejected & ":4:",
      rejected & ":10:"]:
    if not suite.logHas(finding):
      suite.failCase("multi-file scan missed " & finding)

  for malformed in [malformedString, malformedComment]:
    suite.expectFailure("Nim compiler rejection of malformed " &
      malformed.extractFilename, run(cfg.nimExe, @["check"] & nimArguments &
        @[malformed], runEnv = env))
    suite.expectFailure("fail-closed lexical scan of malformed " &
      malformed.extractFilename, run(scanner, @["scan", "--", malformed]))
    if not suite.logHas("Nim source has lexical errors"):
      suite.failCase("malformed source did not report a lexical error")

  copyFile(accepted, work / "-leading.nim")
  copyFile(accepted, work / "source with spaces.nim")
  writeFile(work / "empty.nim", "")
  suite.expectSuccess("leading-dash, whitespace, or empty valid source path",
    run(scanner, @["scan", "--", "-leading.nim", "source with spaces.nim",
      "empty.nim"], cwd = work))
  suite.expectFailure("empty scan input", run(scanner, @["scan", "--"]))
  suite.expectFailure("missing scan delimiter",
    run(scanner, @["scan", accepted]))
  suite.expectFailure("missing source read error",
    run(scanner, @["scan", "--", work / "missing.nim"]))
  copyFile(accepted, work / "unreadable.nim")
  makeUnreadable(cfg, work / "unreadable.nim")
  suite.expectFailure("unreadable source error",
    run(scanner, @["scan", "--", work / "unreadable.nim"]))
  makeReadable(cfg, work / "unreadable.nim")

  # -- The CLOSURE: what the compiler followed, and where it really is ----
  let fakeRepo = work / "repo with spaces"
  let helperSrc = fakeRepo / "libs" / "helper" / "src"
  let sharedSrc = fakeRepo / "shared"
  let externalSrc = work / "external"
  for dir in [helperSrc, sharedSrc / "linked_dir", externalSrc,
      work / "empty-root"]:
    createDir(dir)

  writeFile(helperSrc / "accepted_entry.nim",
    "import std/os\nconst acceptedClosure = DirSep\n")
  suite.compileClosureEntry("accepted-closure", helperSrc / "accepted_entry.nim")
  let acceptedDeps = suite.lastDeps
  suite.expectSuccess("repository sources plus exact trusted Nim standard " &
    "library", closure(fakeRepo, nimLibRoot, helperSrc / "accepted_entry.nim",
      acceptedDeps))

  writeFile(sharedSrc / "outside_module.nim",
    "type\n  OutsideSourceReference = r_e_f object\n    value: int\n")
  writeFile(helperSrc / "outside_entry.nim",
    "import outside_module\nconst importsOutsideSource = true\n")
  suite.compileClosureEntry("outside-src", helperSrc / "outside_entry.nim",
    @["--path:" & sharedSrc])
  suite.expectFailure("ordinary compiler-followed module outside src",
    closure(fakeRepo, nimLibRoot, helperSrc / "outside_entry.nim",
      suite.lastDeps))
  if not suite.logHas(finalPath(sharedSrc / "outside_module.nim") & ":2:"):
    suite.failCase("outside-src dependency was not scanned")

  writeFile(sharedSrc / "file_target.nim",
    "type\n  SymlinkedFileReference = ref object\n    value: int\n")
  suite.link(sharedSrc / "file_target.nim", helperSrc / "file_link.nim")
  writeFile(helperSrc / "file_link_entry.nim",
    "import file_link\nconst importsSymlinkedFile = true\n")
  suite.compileClosureEntry("symlink-file", helperSrc / "file_link_entry.nim")
  suite.expectFailure("compiler-followed symlinked Nim file",
    closure(fakeRepo, nimLibRoot, helperSrc / "file_link_entry.nim",
      suite.lastDeps))
  if not suite.logHas(finalPath(sharedSrc / "file_target.nim") & ":2:"):
    suite.failCase("symlinked file target was not scanned canonically")

  writeFile(sharedSrc / "linked_dir" / "dir_module.nim",
    "type\n  SymlinkedDirectoryReference = ref object\n    value: int\n")
  suite.link(sharedSrc / "linked_dir", helperSrc / "linked_dir")
  writeFile(helperSrc / "dir_link_entry.nim",
    "import linked_dir/dir_module\nconst importsSymlinkedDirectory = true\n")
  suite.compileClosureEntry("symlink-directory",
    helperSrc / "dir_link_entry.nim")
  suite.expectFailure("compiler-followed symlinked Nim directory",
    closure(fakeRepo, nimLibRoot, helperSrc / "dir_link_entry.nim",
      suite.lastDeps))
  if not suite.logHas(finalPath(sharedSrc / "linked_dir" / "dir_module.nim") &
      ":2:"):
    suite.failCase("symlinked directory target was not scanned canonically")

  writeFile(externalSrc / "escape_module.nim", "type ExternalButClean = object\n")
  suite.link(externalSrc / "escape_module.nim", helperSrc / "escape_module.nim")
  writeFile(helperSrc / "escape_entry.nim",
    "import escape_module\nconst importsEscapedModule = true\n")
  suite.compileClosureEntry("symlink-escape", helperSrc / "escape_entry.nim")
  suite.expectFailure("symlink escape outside repository and trusted roots",
    closure(fakeRepo, nimLibRoot, helperSrc / "escape_entry.nim",
      suite.lastDeps))
  if not suite.logHas("outside repository and trusted Nim roots"):
    suite.failCase("symlink escape did not fail the root policy")

  let entry = helperSrc / "accepted_entry.nim"
  let acceptedText = readFile(acceptedDeps)
  suite.expectFailure("missing compiler dependency manifest",
    closure(fakeRepo, nimLibRoot, entry, work / "missing.deps"))
  suite.expectFailure("empty compiler dependency manifest",
    closure(fakeRepo, nimLibRoot, entry, variant("empty.deps", "")))
  let unreadableDeps = variant("unreadable.deps", acceptedText)
  makeUnreadable(cfg, unreadableDeps)
  suite.expectFailure("unreadable compiler dependency manifest",
    closure(fakeRepo, nimLibRoot, entry, unreadableDeps))
  makeReadable(cfg, unreadableDeps)
  suite.expectFailure("duplicate compiler dependency",
    closure(fakeRepo, nimLibRoot, entry,
      variant("duplicate.deps", acceptedText & entry & "\n")))
  suite.expectFailure("compiler dependency manifest missing its entry",
    closure(fakeRepo, nimLibRoot, entry,
      variant("missing-entry.deps", without(acceptedText, entry))))
  suite.expectFailure("blank compiler dependency manifest",
    closure(fakeRepo, nimLibRoot, entry, variant("blank.deps", "\n")))
  suite.expectFailure("NUL-containing compiler dependency manifest",
    closure(fakeRepo, nimLibRoot, entry, variant("nul.deps",
      entry & "\n\0" & nimLibRoot / "system.nim" & "\n")))
  suite.expectFailure("CRLF compiler dependency manifest",
    closure(fakeRepo, nimLibRoot, entry,
      variant("crlf.deps", acceptedText.replace("\n", "\r\n"))))
  suite.expectFailure("untrusted local compiler dependency",
    closure(fakeRepo, nimLibRoot, entry, variant("untrusted-local.deps",
      entry & "\n" & externalSrc / "escape_module.nim" & "\n")))
  suite.expectFailure("dependency from another root of the compiler's package",
    closure(fakeRepo, nimLibRoot, entry, variant("other-root.deps",
      entry & "\n" & cfg.nimExe & "\n")))

  let repoSibling = fakeRepo & "-sibling"
  let trustedRoot = work / "trusted-root"
  let trustedSibling = trustedRoot & "-sibling"
  for dir in [repoSibling, trustedRoot, trustedSibling]:
    createDir(dir)
  writeFile(repoSibling / "prefix_escape.nim", "type RepoPrefixEscape = object\n")
  writeFile(trustedSibling / "prefix_escape.nim",
    "type TrustedPrefixEscape = object\n")
  suite.expectFailure("repository prefix-boundary sibling dependency",
    closure(fakeRepo, nimLibRoot, entry, variant("repo-prefix-boundary.deps",
      entry & "\n" & repoSibling / "prefix_escape.nim" & "\n")))
  suite.expectFailure("trusted-root prefix-boundary sibling dependency",
    closure(fakeRepo, trustedRoot, entry, variant(
      "trusted-prefix-boundary.deps",
      entry & "\n" & trustedSibling / "prefix_escape.nim" & "\n")))
  suite.expectFailure("manifest containing a missing compiler dependency",
    closure(fakeRepo, nimLibRoot, entry, variant("missing-dependency.deps",
      entry & "\n" & work / "missing-dependency.nim" & "\n")))
  suite.expectFailure("empty repository root argument",
    closure("", nimLibRoot, entry, acceptedDeps))
  suite.expectFailure("empty trusted root argument",
    closure(fakeRepo, "", entry, acceptedDeps))
  suite.expectFailure("empty repository root directory",
    closure(work / "empty-root", nimLibRoot, entry, acceptedDeps))
  suite.expectFailure("noncanonical compiler dependency path",
    closure(fakeRepo, nimLibRoot, entry, variant("noncanonical.deps",
      helperSrc & DirSep & ".." & DirSep & "src" & DirSep &
      "accepted_entry.nim\n")))
  suite.expectFailure("relative compiler dependency path",
    closure(fakeRepo, nimLibRoot, entry, variant("relative.deps",
      "libs" & DirSep & "helper" & DirSep & "src" & DirSep &
      "accepted_entry.nim\n")))

  echo "Nim compiler lexer and dependency-closure regression tests passed (" &
    $suite.index & " cases)"

# ---------------------------------------------------------------------------
# The gate (check_static_helpers.sh)
# ---------------------------------------------------------------------------

proc parseConfig(): Config =
  if paramCount() < 1 or paramStr(1) != "gate":
    refuse("usage: static_helper_gate_toolstore gate --<name> <value>...")
  var index = 2
  while index <= paramCount():
    let name = paramStr(index)
    if index + 1 > paramCount():
      refuse("missing value for " & name)
    let value = paramStr(index + 1)
    case name
    of "--host": result.host = value
    of "--nim-root": result.nimRoot = value
    of "--gcc-bin": result.gccBin = value
    of "--git": result.git = value
    of "--repo": result.repo = value
    of "--git-common-dir": result.gitCommonDir = value
    of "--source-tree": result.sourceTree = value
    of "--snapshot": result.snapshot = value
    of "--work": result.work = value
    of "--owner-sid": result.ownerSid = value
    of "--front": result.front = value
    of "--bash": result.bash = value
    of "--caller-path": result.callerPath = value
    of "--authority-file": result.authorityFile = value
    of "--subtree":
      let at = value.find('=')
      if at <= 0:
        refuse("malformed --subtree " & value)
      result.subtrees.add((value[0 ..< at], value[at + 1 .. ^1]))
    else:
      refuse("unknown argument " & name)
    index += 2
  for (name, value) in [("--host", result.host), ("--nim-root", result.nimRoot),
      ("--gcc-bin", result.gccBin), ("--git", result.git),
      ("--repo", result.repo), ("--git-common-dir", result.gitCommonDir),
      ("--source-tree", result.sourceTree), ("--snapshot", result.snapshot),
      ("--work", result.work), ("--owner-sid", result.ownerSid),
      ("--front", result.front), ("--bash", result.bash),
      ("--caller-path", result.callerPath),
      ("--authority-file", result.authorityFile)]:
    if value.len == 0:
      refuse(name & " is required")
  if result.subtrees.len != sourcePaths.len:
    refuse("expected one --subtree for each of " & sourcePaths.join(", "))

proc gate(cfg: Config) =
  let work = cfg.work
  requirePrivate(cfg, work, "gate work root")
  let privateDir = work / "private"
  createDir(privateDir)
  requirePrivate(cfg, privateDir, "gate private directory")

  # The snapshot is the recorded tree, before anything runs.
  verifySource(cfg, cfg.snapshot, privateDir / "source.index",
    privateDir / "source-git.log")

  let buildRoot = work / "build"
  let staticLibRoot = buildRoot / "static-libs"
  let testBinRoot = buildRoot / "test-bin"
  let nimcacheRoot = buildRoot / "nimcache"
  let compilerPrivate = buildRoot / "compiler-private"
  for dir in [staticLibRoot, testBinRoot, nimcacheRoot,
      compilerPrivate / "home", compilerPrivate / "tmp",
      compilerPrivate / "xdg"]:
    createDir(dir)
  requirePrivate(cfg, compilerPrivate, "compiler-private root")
  let env = pinnedEnv(cfg, compilerPrivate / "home", compilerPrivate / "tmp",
    compilerPrivate / "xdg")

  var repoPathArguments: seq[string] = @[]
  for kind, path in walkDir(cfg.snapshot / "libs"):
    if kind == pcDir and dirExists(path / "src"):
      if isLink(path / "src"):
        refuse("repository source directory is a link: " & path / "src")
      repoPathArguments.add("--path:" & (path / "src"))
  if repoPathArguments.len == 0:
    refuse("the source snapshot contains no library source directories")

  let scanner = testBinRoot / "nim_ref_token_scanner.exe"
  let bootstrapRoot = buildRoot / "nim-scanner-bootstrap"
  createDir(bootstrapRoot)
  let nimRoot = bootstrapScanner(cfg, cfg.nimExe,
    cfg.snapshot / "scripts" / "nim_ref_token_scanner.nim", scanner,
    bootstrapRoot)
  let nimLibRoot = nimRoot / "lib"

  runSelfTest(cfg, scanner, nimRoot, bootstrapRoot)

  let log = buildRoot / "static-helper.log"
  var checked = 0
  for raw in readFile(cfg.snapshot / "libs" / "static_helpers.txt").splitLines:
    let lib = raw.strip.split(' ')[0]
    if lib.len == 0 or lib.startsWith("#"):
      continue
    let entry = cfg.snapshot / "libs" / lib / "src" / (lib & ".nim")
    if not isRegularFile(entry):
      refuse("static-helper entry is not a regular file: " & entry)
    let nimcache = nimcacheRoot / ("static-" & lib)
    let deps = nimcache / (lib & ".deps")
    let archive = staticLibRoot / ("lib" & lib & ".a")
    removeDir(nimcache)
    if fileExists(archive):
      removeFile(archive)
    let arguments = @["c", "--skipCfg:on", "--skipUserCfg:on",
      "--skipParentCfg:on", "--skipProjCfg:on", "--cc:gcc", "--mm:arc",
      "--app:staticlib", "--nimcache:" & nimcache, "--out:" & archive] &
      repoPathArguments
    if runLogged(cfg.nimExe, arguments & @["--genScript:on", entry], log,
        env) != 0:
      refuse("ARC static-library compile (manifest pass) of " & lib &
        " failed:\n" & readFile(log))
    if not fileExists(deps):
      refuse("Nim compiler did not emit dependency manifest " & deps)
    if runLogged(testBinRoot / "nim_ref_token_scanner.exe", ["closure",
        cfg.snapshot, nimLibRoot, entry, deps], log) != 0:
      refuse("Nim ref type token found in static helper " & lib & ":\n" &
        readFile(log))
    if fileExists(archive):
      removeFile(archive)
    if runLogged(cfg.nimExe, arguments & @[entry], log, env) != 0:
      refuse("ARC static-library compile of " & lib & " failed:\n" &
        readFile(log))
    if not fileExists(archive) or getFileSize(archive) == 0:
      refuse("Nim did not build static helper archive for " & lib)
    inc checked
    echo "  static helper ", lib, ": ARC staticlib built, closure ref-free"
  if checked == 0:
    refuse("libs/static_helpers.txt names no library")

  # And nothing any of it ran changed what was scanned.
  verifySource(cfg, cfg.snapshot, privateDir / "source.index",
    privateDir / "source-git.log")
  echo "runquota static helper checks passed (tool-store authority, ",
    checked, " libraries)"

when isMainModule:
  try:
    gate(parseConfig())
  except GateError as error:
    stderr.writeLine("RunQuota static-helper gate (tool-store authority) " &
      "failure: " & error.msg)
    quit 1
