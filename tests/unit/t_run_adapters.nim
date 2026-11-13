## Table-driven tests of the `runquota run` width adapters and of the
## argument/width/stats-key rules around them.
##
## NO MOCKS. The adapters are pure functions of `(argv, grant)`, so every
## case is a command line in and a command line out; nothing here starts a
## process. (The behaviour of the resulting command lines against real tools
## is covered by `tests/integration/t_run_command.nim`.)
import std/[os, strutils, unittest]

import runquota_cli_support/run_adapters
import runquota_cli_support/run_command

proc adapt(adapterName: string; line: string; grant: int): string =
  ## Applies the NAMED adapter to a whitespace-separated command line and
  ## returns the result joined by spaces.
  let argv = line.splitWhitespace()
  let index = findAdapter(adapterName)
  doAssert index >= 0, "no adapter " & adapterName
  applyAdapter(registry()[index], argv, grant).argv.join(" ")

proc detected(line: string): string =
  let index = detectAdapter(line.splitWhitespace())
  if index < 0: "" else: registry()[index].name

type Case = tuple[adapter, input: string; grant: int; want: string]

suite "adapter command-line rewriting":
  test "every adapter adds its flag, or respects and caps the user's":
    let cases: seq[Case] = @[
      # nim
      ("nim", "nim c x.nim", 3, "nim c --parallelBuild:3 x.nim"),
      ("nim", "nim cpp -d:release x.nim", 4,
        "nim cpp --parallelBuild:4 -d:release x.nim"),
      ("nim", "nim c --parallelBuild:2 x.nim", 3,
        "nim c --parallelBuild:2 x.nim"),
      ("nim", "nim c --parallelBuild:16 x.nim", 3,
        "nim c --parallelBuild:3 x.nim"),
      ("nim", "nim c --parallelBuild:0 x.nim", 3,
        "nim c --parallelBuild:3 x.nim"),
      ("nim", "nim c --parallelBuild=9 x.nim", 3,
        "nim c --parallelBuild=3 x.nim"),
      ("nim", "nim --hints:off c x.nim", 2,
        "nim --hints:off c --parallelBuild:2 x.nim"),
      # go
      ("go", "go build ./...", 3, "go build -p 3 ./..."),
      ("go", "go test ./... -run X", 2, "go test -p 2 ./... -run X"),
      ("go", "go build -p 2 ./...", 3, "go build -p 2 ./..."),
      ("go", "go build -p 12 ./...", 3, "go build -p 3 ./..."),
      ("go", "go build -p=12 ./...", 3, "go build -p=3 ./..."),
      ("go", "go test ./... -args -p 99", 3,
        "go test -p 3 ./... -args -p 99"),
      # cargo nextest
      ("nextest", "cargo nextest run", 4, "cargo nextest run -j 4"),
      ("nextest", "cargo +nightly nextest run -p foo", 4,
        "cargo +nightly nextest run -j 4 -p foo"),
      ("nextest", "cargo nextest run -j 2", 4, "cargo nextest run -j 2"),
      ("nextest", "cargo nextest run -j 64", 4, "cargo nextest run -j 4"),
      ("nextest", "cargo nextest run -j64", 4, "cargo nextest run -j4"),
      ("nextest", "cargo nextest run --test-threads=99", 4,
        "cargo nextest run --test-threads=4"),
      ("nextest", "cargo nextest run -j num-cpus", 4,
        "cargo nextest run -j 4"),
      ("nextest", "cargo nextest run -- -j 99", 4,
        "cargo nextest run -j 4 -- -j 99"),
      # Playwright
      ("playwright", "playwright test", 2, "playwright test --workers=2"),
      ("playwright", "npx playwright test a.spec.ts", 3,
        "npx playwright test --workers=3 a.spec.ts"),
      ("playwright", "pnpm exec playwright test --workers=1", 3,
        "pnpm exec playwright test --workers=1"),
      ("playwright", "playwright test --workers=50%", 3,
        "playwright test --workers=3"),
      ("playwright", "playwright test --workers 10", 3,
        "playwright test --workers 3"),
      ("playwright", "playwright test -j8", 3, "playwright test -j3"),
      # nix: jobs x cores never exceeds the grant
      ("nix", "nix build .#x", 4, "nix build --max-jobs 1 --cores 4 .#x"),
      ("nix", "nix --extra-experimental-features nix-command build .#x", 4,
        "nix --extra-experimental-features nix-command build --max-jobs 1 " &
        "--cores 4 .#x"),
      ("nix", "nix-build default.nix", 4,
        "nix-build --max-jobs 1 --cores 4 default.nix"),
      ("nix", "nix build --max-jobs 2 .#x", 4,
        "nix build --cores 2 --max-jobs 2 .#x"),
      ("nix", "nix build --max-jobs 100 .#x", 4,
        "nix build --cores 1 --max-jobs 4 .#x"),
      ("nix", "nix build --max-jobs auto .#x", 4,
        "nix build --cores 4 --max-jobs 1 .#x"),
      ("nix", "nix build --cores 2 .#x", 4,
        "nix build --max-jobs 1 --cores 2 .#x"),
      ("nix", "nix build --cores 0 .#x", 4,
        "nix build --max-jobs 1 --cores 4 .#x"),
      ("nix", "nix build --cores=64 .#x", 4,
        "nix build --max-jobs 1 --cores=4 .#x"),
      ("nix", "nix build -j 2 --cores 8 .#x", 4,
        "nix build -j 2 --cores 2 .#x"),
      # pnpm
      ("pnpm", "pnpm -r run build", 3,
        "pnpm --workspace-concurrency=3 -r run build"),
      ("pnpm", "pnpm run build -- --foo", 3,
        "pnpm --workspace-concurrency=3 run build -- --foo"),
      ("pnpm", "pnpm -r --workspace-concurrency=2 run build", 3,
        "pnpm -r --workspace-concurrency=2 run build"),
      ("pnpm", "pnpm -r --workspace-concurrency=20 run build", 3,
        "pnpm -r --workspace-concurrency=3 run build"),
      ("pnpm", "pnpm -r --workspace-concurrency=0 run build", 3,
        "pnpm -r --workspace-concurrency=3 run build"),
      # yarn (Yarn 2+ foreach only)
      ("yarn", "yarn workspaces foreach -A run build", 3,
        "yarn workspaces foreach --jobs 3 -A run build"),
      ("yarn", "yarn workspaces foreach -p -j 2 run build", 3,
        "yarn workspaces foreach -p -j 2 run build"),
      ("yarn", "yarn workspaces foreach -p --jobs 20 run build", 3,
        "yarn workspaces foreach -p --jobs 3 run build"),
      ("yarn", "yarn workspaces foreach -A run test -j 99", 3,
        "yarn workspaces foreach --jobs 3 -A run test -j 99"),
      # not recognised or no knob: unchanged
      ("yarn", "yarn install", 3, "yarn install"),
      ("npm", "npm run build --workspaces", 3, "npm run build --workspaces"),
      ("nim", "nim --version", 3, "nim --version"),
      ("go", "go mod tidy", 3, "go mod tidy"),
      ("nix", "nix develop", 3, "nix develop"),
      ("nextest", "cargo build", 3, "cargo build")]
    for (name, input, grant, want) in cases:
      check adapt(name, input, grant) == want

  test "detection picks the right adapter, and none for anything else":
    let table = [
      ("nim c x.nim", "nim"),
      ("/usr/bin/go build ./...", "go"),
      ("cargo nextest run", "nextest"),
      ("cargo test", ""),
      ("nix build .#x", "nix"),
      ("nix-build", "nix"),
      ("nix develop", ""),
      ("pnpm -r build", "pnpm"),
      ("pnpm exec playwright test", "playwright"),
      ("npx playwright test", "playwright"),
      ("playwright test", "playwright"),
      ("yarn workspaces foreach run x", "yarn"),
      ("yarn build", ""),
      ("npm run x", "npm"),
      ("make -j4", ""),
      ("./build.sh", "")]
    for (line, want) in table:
      check detected(line) == want
    check baseName("C:\\tools\\Go.EXE") == "go"

  test "the grant is never exceeded by what an adapter emits":
    # A property over grants 1..16 for the flag a user could set too wide.
    for grant in 1 .. 16:
      check adapt("go", "go build -p 1000 ./...", grant) ==
        "go build -p " & $grant & " ./..."
      let nixLine = adapt("nix", "nix build --max-jobs 7 --cores 9 .#x", grant)
      let words = nixLine.splitWhitespace()
      let jobs = parseInt(words[words.find("--max-jobs") + 1])
      let cores = parseInt(words[words.find("--cores") + 1])
      check jobs * cores <= grant

  test "an unrecognised command is passed through with a note":
    let outcome = applyAdapter(registry()[findAdapter("go")],
      @["make", "-j8"], 3)
    check outcome.argv == @["make", "-j8"]
    check not outcome.applied
    check outcome.notes.len == 1

  test "the registry lists every adapter":
    let text = renderAdapterList()
    for name in ["nim", "go", "nextest", "nix", "pnpm", "yarn", "playwright",
        "npm", "none"]:
      check name in text

suite "run argument rules":
  test "width syntax":
    var lo, pref: int
    check parseWidthRange("3", lo, pref) and lo == 3 and pref == 3
    check parseWidthRange("2:6", lo, pref) and lo == 2 and pref == 6
    check parseWidthRange("2:", lo, pref) and lo == 2 and pref == 0
    check parseWidthRange(":6", lo, pref) and lo == 1 and pref == 6
    for bad in ["", "0", "-1", "a", "6:2", "1:0", "1:2:3", "3x"]:
      check not parseWidthRange(bad, lo, pref)

  test "options":
    var options: RunOptions
    var error = ""
    check parseRunArgs(@["--width", "3", "--stats-key", "k", "--", "nim", "c"],
      options, error)
    check options.minWidth == 3 and options.preferredWidth == 3
    check options.statsKey == "k"
    check options.command == @["nim", "c"]
    # The command's own flags after `--` are never read.
    check parseRunArgs(@["--", "go", "--cap", "--width", "9"], options, error)
    check not options.cap and options.command.len == 4
    check not parseRunArgs(@["--width", "3"], options, error)
    check not parseRunArgs(@["--bogus", "--", "x"], options, error)
    check not parseRunArgs(@["--adapter", "nosuch", "--", "x"], options, error)
    check parseRunArgs(@["--adapter", "list"], options, error)
    check options.listAdapters

  test "the width ladder asks widest first and ends at MIN":
    check widthLadder(8, 1) == @[8, 4, 2, 1]
    check widthLadder(8, 3) == @[8, 4, 3]
    check widthLadder(3, 3) == @[3]
    check widthLadder(1, 1) == @[1]

  test "learned width is absent until the daemon can supply one":
    var options: RunOptions
    var error = ""
    doAssert parseRunArgs(@["--", "x"], options, error)
    check preferredWidthFor(options, "k") == defaultPreferredWidth()
    doAssert parseRunArgs(@["--width", "5:", "--", "x"], options, error)
    check preferredWidthFor(options, "k") >= 5

  test "stats key derives from the program and the project of the cwd":
    let root = getTempDir() / ("rq-run-key-" & $getCurrentProcessId())
    createDir(root / "proj" / ".git")
    createDir(root / "proj" / "sub" / "deep")
    defer: removeDir(root)
    check deriveStatsKey(@["/usr/bin/nim", "c"], root / "proj" / "sub" /
        "deep") ==
      "run/nim@proj"
    check deriveStatsKey(@["go"], root / "proj") == "run/go@proj"
