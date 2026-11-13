## Width adapters for `runquota run`.
##
## An adapter turns a CPU grant into the command line (and environment) a
## particular tool understands: `nim c --parallelBuild:N`, `go build -p N`,
## `cargo nextest run -j N`, and so on. Each one is a PURE FUNCTION
## `(argv, grant) -> argv + env`: it opens no connection, reads no
## environment and starts no process, which is what lets the table in
## `tests/unit/t_run_adapters.nim` pin every rule without a daemon.
##
## THE RULES EVERY ADAPTER SHARES
##
## 1. `locate` decides whether an adapter RECOGNISES a command, from `argv`
##    alone. Detection is by the program's base name (lower-cased, with a
##    Windows `.exe`/`.cmd`/`.bat` suffix removed) and the first positional
##    word, never by guessing at what a script might run underneath.
## 2. A width flag the user already put on the command line is RESPECTED and
##    CAPPED, never replaced wholesale: a value from 1 up to the grant stays
##    exactly as written; a larger value, `0`, a negative number or anything
##    that is not a plain integer (`50%`, `auto`, `unlimited`) becomes the
##    grant, because none of those can be shown to fit inside it.
## 3. A command that is not recognised, or recognised but with no width knob
##    (`npm`), is passed through UNCHANGED, with a note saying so.
## 4. Flags are inserted immediately after the word that selects the
##    sub-command, so they land before any `--` that hands the rest of the
##    line to a test binary or a script.
##
## The grant is a whole number of CPU slots, at least 1.
import std/[strutils]

type
  AdapterOutcome* = object
    argv*: seq[string]
    env*: seq[string]
      ## `KEY=VALUE` pairs layered over the inherited environment.
    notes*: seq[string]
      ## What the adapter did or declined to do, for `--verbose`.
    applied*: bool
      ## Whether the command was recognised and bounded (or already within
      ## the grant). False for a pass-through.

  LocateProc* = proc(argv: seq[string]): int {.nimcall.}
    ## The index of the token AFTER WHICH new flags are inserted, or -1 when
    ## the command is not one this adapter handles.
  EditProc* = proc(argv: seq[string]; at,
      grant: int): AdapterOutcome {.nimcall.}

  Adapter* = object
    name*: string
    summary*: string
    rules*: string
    locate*: LocateProc
    edit*: EditProc

  FlagForm = enum
    ffSeparate ## `--workers 4`: the value is the next token
    ffEquals   ## `--workers=4` / `--parallelBuild:4`
    ffAttached ## `-j4`

  FlagHit = object
    form: FlagForm
    flagIdx: int
    valueIdx: int  ## index of the token holding the value text
    prefix: string ## text before the value inside that token
    text: string   ## the value as the user wrote it

proc baseName*(argv0: string): string =
  ## The program name used for detection: the last path component,
  ## lower-cased, without a Windows launcher suffix.
  var name = argv0
  let slash = max(name.rfind('/'), name.rfind('\\'))
  if slash >= 0: name = name[slash + 1 .. ^1]
  name = name.toLowerAscii()
  for suffix in [".exe", ".cmd", ".bat"]:
    if name.endsWith(suffix):
      name = name[0 ..< name.len - suffix.len]
      break
  name

# ---------------------------------------------------------------------------
# Shared flag machinery
# ---------------------------------------------------------------------------

proc parseWidth(text: string): int =
  ## A plain positive integer, or -1. Anything else cannot be compared with
  ## a grant.
  if text.len == 0 or text.len > 9: return -1
  for ch in text:
    if ch notin {'0' .. '9'}: return -1
  result = parseInt(text)
  if result < 1: result = -1

proc capText(text: string; limit: int): string =
  ## Rule 2: keep a value that is within the limit, else the limit.
  let n = parseWidth(text)
  if n >= 1 and n <= limit: text else: $limit

proc findFlags(argv: seq[string]; first, stop: int; names: openArray[string];
               attached = ""; equalsSeparators = "=:";
               allowSeparate = true): seq[FlagHit] =
  ## Every occurrence of any of `names` in `argv[first ..< stop]`.
  ## `attached` is a short flag that may be glued to its value (`-j4`).
  var i = first
  while i < stop:
    let token = argv[i]
    var matched = false
    for name in names:
      if token == name:
        if allowSeparate and i + 1 < stop:
          result.add FlagHit(form: ffSeparate, flagIdx: i, valueIdx: i + 1,
            prefix: "", text: argv[i + 1])
          i += 1
        matched = true
        break
      for sep in equalsSeparators:
        let head = name & $sep
        if token.startsWith(head):
          result.add FlagHit(form: ffEquals, flagIdx: i, valueIdx: i,
            prefix: head, text: token[head.len .. ^1])
          matched = true
          break
      if matched: break
    if not matched and attached.len > 0 and token.len > attached.len and
        token.startsWith(attached) and token[attached.len] in {'0' .. '9'}:
      result.add FlagHit(form: ffAttached, flagIdx: i, valueIdx: i,
        prefix: attached, text: token[attached.len .. ^1])
    inc i

proc rewrite(argv: var seq[string]; hit: FlagHit; value: string) =
  case hit.form
  of ffSeparate: argv[hit.valueIdx] = value
  of ffEquals, ffAttached: argv[hit.valueIdx] = hit.prefix & value

proc insertAfter(argv: seq[string]; at: int; extra: openArray[string]):
    seq[string] =
  result = argv[0 .. at]
  for item in extra: result.add item
  if at + 1 < argv.len: result.add argv[at + 1 .. ^1]

proc firstPositional(argv: seq[string]; first: int;
                     valueFlags: openArray[string] = []): int =
  ## Index of the first token from `first` on that is not a flag nor the
  ## value of a flag in `valueFlags`; -1 when none.
  var i = first
  while i < argv.len:
    let token = argv[i]
    if token == "--": return -1
    if token.startsWith("-"):
      i += (if token in valueFlags: 2 else: 1)
    else:
      return i
  -1

proc untilTerminator(argv: seq[string]; first: int;
                     extra: openArray[string] = []): int =
  ## The end of the region in which flags are read: the first `--` (or one
  ## of `extra`, such as Go's `-args`), else the end of the line.
  result = argv.len
  for i in first ..< argv.len:
    if argv[i] == "--" or argv[i] in extra:
      return i

proc capHits(argv: var seq[string]; hits: seq[FlagHit]; grant: int;
             label: string; notes: var seq[string]) =
  for hit in hits:
    let capped = capText(hit.text, grant)
    if capped != hit.text:
      argv.rewrite(hit, capped)
      notes.add label & " " & hit.text & " exceeds or cannot be shown to " &
        "fit the grant; capped to " & capped
    else:
      notes.add label & " " & hit.text & " kept (within the grant)"

proc unchanged(argv: seq[string]; note: string): AdapterOutcome =
  AdapterOutcome(argv: argv, notes: @[note], applied: false)

# ---------------------------------------------------------------------------
# nim
# ---------------------------------------------------------------------------

const NimCompileCommands = ["c", "cc", "cpp", "objc", "js", "r", "compile",
  "compiletoc", "compiletocpp", "compiletooc", "compiletojs"]

proc locateNim(argv: seq[string]): int =
  if argv.len < 2 or baseName(argv[0]) != "nim": return -1
  let sub = firstPositional(argv, 1)
  if sub >= 0 and argv[sub].toLowerAscii() in NimCompileCommands: sub else: -1

proc editNim(argv: seq[string]; at, grant: int): AdapterOutcome =
  ## `--parallelBuild:N` makes the Nim driver run up to N C compiler
  ## processes at once. `--parallelBuild:0` means "all cores", so it is
  ## capped like any other over-wide value.
  var args = argv
  var notes: seq[string] = @[]
  let hits = findFlags(args, 1, args.len, ["--parallelBuild", "-parallelBuild"],
    allowSeparate = false)
  if hits.len > 0:
    capHits(args, hits, grant, "--parallelBuild", notes)
  else:
    args = insertAfter(args, at, ["--parallelBuild:" & $grant])
    notes.add "added --parallelBuild:" & $grant
  AdapterOutcome(argv: args, notes: notes, applied: true)

# ---------------------------------------------------------------------------
# go
# ---------------------------------------------------------------------------

const GoCommands = ["build", "install", "test", "vet"]

proc locateGo(argv: seq[string]): int =
  if argv.len < 2 or baseName(argv[0]) != "go": return -1
  let sub = firstPositional(argv, 1)
  if sub >= 0 and argv[sub] in GoCommands: sub else: -1

proc editGo(argv: seq[string]; at, grant: int): AdapterOutcome =
  ## `-p N` bounds the number of programs (for `go test`, packages) run in
  ## parallel. Go accepts `-p`, `--p`, `-p=N` and `-p N`. Flags after
  ## `-args` or `--` belong to the program under test and are not read.
  var args = argv
  var notes: seq[string] = @[]
  let stop = untilTerminator(args, at + 1, ["-args"])
  let hits = findFlags(args, at + 1, stop, ["-p", "--p"],
    equalsSeparators = "=")
  if hits.len > 0:
    capHits(args, hits, grant, "-p", notes)
  else:
    args = insertAfter(args, at, ["-p", $grant])
    notes.add "added -p " & $grant
  AdapterOutcome(argv: args, notes: notes, applied: true)

# ---------------------------------------------------------------------------
# cargo nextest
# ---------------------------------------------------------------------------

proc locateNextest(argv: seq[string]): int =
  ## `cargo [+toolchain] nextest run ...`: the insertion point is the `run`
  ## word.
  if argv.len < 3 or baseName(argv[0]) != "cargo": return -1
  var i = 1
  if argv[i].startsWith("+"): inc i
  if i + 1 >= argv.len or argv[i] != "nextest": return -1
  if argv[i + 1] == "run": i + 1 else: -1

proc editNextest(argv: seq[string]; at, grant: int): AdapterOutcome =
  ## `-j N` / `--test-threads N` is the number of tests run at once.
  var args = argv
  var notes: seq[string] = @[]
  let stop = untilTerminator(args, at + 1)
  let hits = findFlags(args, at + 1, stop, ["-j", "--test-threads"],
    attached = "-j")
  if hits.len > 0:
    capHits(args, hits, grant, "-j", notes)
  else:
    args = insertAfter(args, at, ["-j", $grant])
    notes.add "added -j " & $grant
  AdapterOutcome(argv: args, notes: notes, applied: true)

# ---------------------------------------------------------------------------
# Playwright
# ---------------------------------------------------------------------------

const PlaywrightRunners = ["npx", "pnpm", "yarn", "npm", "bunx", "bun"]

proc locatePlaywright(argv: seq[string]): int =
  ## `playwright test ...`, or the same behind a package runner
  ## (`npx playwright test`, `pnpm exec playwright test`): the first
  ## adjacent `playwright test` pair; the insertion point is `test`.
  if argv.len < 2: return -1
  let program = baseName(argv[0])
  if program == "playwright":
    return (if argv[1] == "test": 1 else: -1)
  if program notin PlaywrightRunners: return -1
  for i in 1 ..< argv.len - 1:
    if baseName(argv[i]) == "playwright" and argv[i + 1] == "test":
      return i + 1
  -1

proc editPlaywright(argv: seq[string]; at, grant: int): AdapterOutcome =
  ## `--workers=N` is the number of worker processes. Percentages such as
  ## `--workers=50%` are capped to the grant like any other value that
  ## cannot be compared with it.
  var args = argv
  var notes: seq[string] = @[]
  let hits = findFlags(args, at + 1, args.len, ["--workers", "-j"],
    attached = "-j")
  if hits.len > 0:
    capHits(args, hits, grant, "--workers", notes)
  else:
    args = insertAfter(args, at, ["--workers=" & $grant])
    notes.add "added --workers=" & $grant
  AdapterOutcome(argv: args, notes: notes, applied: true)

# ---------------------------------------------------------------------------
# nix
# ---------------------------------------------------------------------------

const
  NixValueFlags = ["--extra-experimental-features", "--experimental-features",
    "--store", "--eval-store", "--log-format", "--substituters"]
  NixTwoValueFlags = ["--option"]

proc locateNix(argv: seq[string]): int =
  ## `nix [global flags] build ...` (insertion after `build`) or
  ## `nix-build ...` (insertion after the program).
  if argv.len < 1: return -1
  let program = baseName(argv[0])
  if program == "nix-build": return 0
  if program != "nix": return -1
  var i = 1
  while i < argv.len:
    let token = argv[i]
    if token == "--": return -1
    if token.startsWith("-"):
      if token in NixTwoValueFlags: i += 3
      elif token in NixValueFlags: i += 2
      else: i += 1
    else:
      return (if token == "build": i else: -1)
  -1

proc editNix(argv: seq[string]; at, grant: int): AdapterOutcome =
  ## The grant is shared between `--max-jobs` (builds at once) and
  ## `--cores` (cores per build), so that jobs x cores never exceeds it:
  ##
  ## - neither given: `--max-jobs 1 --cores GRANT`;
  ## - only `--max-jobs M` given: M is capped to the grant and
  ##   `--cores` becomes `GRANT div M` (at least 1);
  ## - `--cores C` given: C is capped to `GRANT div M` where M is the
  ##   user's (capped) `--max-jobs`, or 1 when absent.
  ##
  ## A non-numeric `--max-jobs` (`auto`) counts as 1. The user's own flags
  ## are rewritten in place; nothing is appended for a flag already present.
  ## Nix settings are applied by the nix daemon only if the user is allowed
  ## to set them (`trusted-users`); that is nix's decision, not ours.
  var args = argv
  var notes: seq[string] = @[]
  let stop = untilTerminator(args, at + 1)
  let jobHits = findFlags(args, at + 1, stop, ["--max-jobs", "-j"],
    attached = "-j", equalsSeparators = "=")
  let coreHits = findFlags(args, at + 1, stop, ["--cores"],
    equalsSeparators = "=")

  var jobs = 1
  if jobHits.len > 0:
    let parsed = parseWidth(jobHits[^1].text)
    jobs = if parsed < 1: 1 else: min(parsed, grant)
    for hit in jobHits:
      args.rewrite(hit, $jobs)
    notes.add "--max-jobs " & jobHits[^1].text & " kept as " & $jobs
  let coresLimit = max(1, grant div jobs)
  var extra: seq[string] = @[]
  if jobHits.len == 0:
    extra.add "--max-jobs"
    extra.add "1"
    notes.add "added --max-jobs 1"
  if coreHits.len > 0:
    for hit in coreHits:
      let n = parseWidth(hit.text)
      let capped = if n >= 1 and n <= coresLimit: n else: coresLimit
      args.rewrite(hit, $capped)
      notes.add "--cores " & hit.text & " kept as " & $capped
  else:
    extra.add "--cores"
    extra.add $coresLimit
    notes.add "added --cores " & $coresLimit
  if extra.len > 0:
    args = insertAfter(args, at, extra)
  AdapterOutcome(argv: args, notes: notes, applied: true)

# ---------------------------------------------------------------------------
# pnpm, yarn, npm
# ---------------------------------------------------------------------------

const
  PnpmWorkspaceCommands = ["run", "run-script", "exec", "test", "t", "install",
    "i", "rebuild", "rb", "publish", "update", "up", "add", "dlx"]
  PnpmValueFlags = ["-C", "--dir", "--filter", "-F", "--filter-prod",
    "--workspace-concurrency", "--reporter", "--config"]

proc locatePnpm(argv: seq[string]): int =
  ## A pnpm command that can fan out over workspace projects: `-r` /
  ## `--recursive` / `--filter`, or one of the commands that run scripts or
  ## install. Insertion is right after the program, before any
  ## sub-command, so the flag is read by pnpm and never handed to a script.
  if argv.len < 2 or baseName(argv[0]) != "pnpm": return -1
  let stop = untilTerminator(argv, 1)
  for i in 1 ..< stop:
    if argv[i] in ["-r", "--recursive", "--filter", "-F"] or
        argv[i].startsWith("--filter=") or
        argv[i].startsWith("--workspace-concurrency"):
      return 0
  let sub = firstPositional(argv, 1, PnpmValueFlags)
  if sub >= 0 and argv[sub] in PnpmWorkspaceCommands: 0 else: -1

proc editPnpm(argv: seq[string]; at, grant: int): AdapterOutcome =
  ## `--workspace-concurrency=N` bounds how many workspace projects run
  ## their scripts at once. (Scripts that start their own parallelism are
  ## bounded by their own adapter, not by this one.)
  var args = argv
  var notes: seq[string] = @[]
  let hits = findFlags(args, 1, untilTerminator(args, 1),
    ["--workspace-concurrency"])
  if hits.len > 0:
    capHits(args, hits, grant, "--workspace-concurrency", notes)
  else:
    args = insertAfter(args, at, ["--workspace-concurrency=" & $grant])
    notes.add "added --workspace-concurrency=" & $grant
  AdapterOutcome(argv: args, notes: notes, applied: true)

const YarnForeachValueFlags = ["-j", "--jobs", "--include", "--exclude",
  "--from", "--since"]

proc locateYarn(argv: seq[string]): int =
  ## `yarn workspaces foreach ...` (Yarn 2+). The insertion point is the
  ## word `foreach`. Yarn 1 and every other yarn command have no workspace
  ## concurrency knob and are not recognised.
  if argv.len < 3 or baseName(argv[0]) != "yarn": return -1
  for i in 1 ..< argv.len - 1:
    if argv[i] == "workspaces" and argv[i + 1] == "foreach":
      return i + 1
    if not argv[i].startsWith("-"): return -1
  -1

proc editYarn(argv: seq[string]; at, grant: int): AdapterOutcome =
  ## `--jobs N` is the number of workspaces run at once, and takes effect
  ## together with the user's own `--parallel`/`--topological`. Options of
  ## `foreach` end at its first positional word (the command to run), so a
  ## `-j` belonging to that command is never mistaken for ours.
  var args = argv
  var notes: seq[string] = @[]
  var stop = at + 1
  while stop < args.len and args[stop].startsWith("-"):
    stop += (if args[stop] in YarnForeachValueFlags: 2 else: 1)
  stop = min(stop, args.len)
  let hits = findFlags(args, at + 1, stop, ["--jobs", "-j"], attached = "-j",
    equalsSeparators = "=")
  if hits.len > 0:
    capHits(args, hits, grant, "--jobs", notes)
  else:
    args = insertAfter(args, at, ["--jobs", $grant])
    notes.add "added --jobs " & $grant
  AdapterOutcome(argv: args, notes: notes, applied: true)

proc locateNpm(argv: seq[string]): int =
  if argv.len >= 2 and baseName(argv[0]) == "npm": 0 else: -1

proc editNpm(argv: seq[string]; at, grant: int): AdapterOutcome =
  ## npm has no workspace-concurrency setting: `npm run --workspaces` runs
  ## the workspaces one after another. Nothing can be bounded here, so the
  ## command is passed through and the grant is still held for its
  ## duration. Scripts that start parallel work can read
  ## `RUNQUOTA_RUN_WIDTH`.
  unchanged(argv, "npm has no workspace concurrency setting; command " &
    "passed through unchanged")

# ---------------------------------------------------------------------------
# Registry
# ---------------------------------------------------------------------------

proc registry*(): seq[Adapter] =
  ## Detection order matters: Playwright is tried before the package
  ## runners (`pnpm exec playwright test` is a Playwright command).
  @[
    Adapter(name: "playwright",
      summary: "Playwright: --workers=N",
      rules: "`playwright test`, or `npx|pnpm|yarn|npm|bunx|bun ... " &
        "playwright test`; flag inserted after `test`; respects " &
        "--workers/-j",
      locate: locatePlaywright, edit: editPlaywright),
    Adapter(name: "nextest",
      summary: "cargo nextest: -j N",
      rules: "`cargo [+toolchain] nextest run`; flag inserted after `run`; " &
        "respects -j/--test-threads",
      locate: locateNextest, edit: editNextest),
    Adapter(name: "go",
      summary: "go build/install/test/vet: -p N",
      rules: "`go build|install|test|vet`; flag inserted after the " &
        "sub-command; respects -p and ignores anything after -args",
      locate: locateGo, edit: editGo),
    Adapter(name: "nim",
      summary: "nim c/cpp/objc/js/r: --parallelBuild:N",
      rules: "`nim c|cc|cpp|objc|js|r|compile*`; flag inserted after the " &
        "sub-command; respects --parallelBuild",
      locate: locateNim, edit: editNim),
    Adapter(name: "nix",
      summary: "nix build / nix-build: --max-jobs 1 --cores N",
      rules: "`nix [flags] build` or `nix-build`; jobs x cores never " &
        "exceeds the grant; respects --max-jobs/-j and --cores",
      locate: locateNix, edit: editNix),
    Adapter(name: "pnpm",
      summary: "pnpm workspaces: --workspace-concurrency=N",
      rules: "`pnpm` with -r/--recursive/--filter or a script-running or " &
        "install command; flag inserted right after `pnpm`; respects " &
        "--workspace-concurrency",
      locate: locatePnpm, edit: editPnpm),
    Adapter(name: "yarn",
      summary: "yarn workspaces foreach: --jobs N (Yarn 2+)",
      rules: "`yarn workspaces foreach`; flag inserted after `foreach`; " &
        "respects -j/--jobs. Yarn 1 has no such option",
      locate: locateYarn, edit: editYarn),
    Adapter(name: "npm",
      summary: "npm: no concurrency setting (pass-through)",
      rules: "`npm ...`; npm has no workspace concurrency option, so the " &
        "command is not changed",
      locate: locateNpm, edit: editNpm)]

proc findAdapter*(name: string): int =
  ## Index into `registry()` of the adapter called `name`, or -1.
  let all = registry()
  for i, adapter in all:
    if adapter.name == name: return i
  -1

proc detectAdapter*(argv: seq[string]): int =
  ## Index of the first adapter that recognises `argv`, or -1.
  let all = registry()
  for i, adapter in all:
    if adapter.locate(argv) >= 0: return i
  -1

proc applyAdapter*(adapter: Adapter; argv: seq[string]; grant: int):
    AdapterOutcome =
  ## Rewrites `argv` for a grant of `grant` slots. An adapter that does not
  ## recognise the command returns it unchanged with a note.
  doAssert grant >= 1, "a grant is at least one slot"
  if argv.len == 0:
    return AdapterOutcome(argv: argv, notes: @["empty command"])
  let at = adapter.locate(argv)
  if at < 0:
    return unchanged(argv, "adapter " & adapter.name &
      " does not recognise this command; passed through unchanged")
  result = adapter.edit(argv, at, grant)

proc renderAdapterList*(): string =
  ## The text of `runquota run --adapter list`.
  var lines = @["adapters (tried in this order when --adapter is not given):"]
  for adapter in registry():
    lines.add "  " & alignLeft(adapter.name, 11) & adapter.summary
    lines.add "              " & adapter.rules
  lines.add "  none       no command-line change; the lease is still held"
  lines.join("\n")
