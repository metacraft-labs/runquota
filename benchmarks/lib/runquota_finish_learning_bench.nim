## The daemon CPU the learned-estimate store's writes cost per finish.
##
## A finish that carries a measured tree peak (a `FinishMemoryCap` block) is
## folded into its command's learned row in memory, and the row is queued for
## the estimate store's background writer, which commits it to SQLite. This
## tool isolates the second half. Both arms run a private `runquotad`, one
## session, and `--finishes` leases of ONE command stats id, each finish
## carrying a block whose tree peak varies BELOW the command's recorded
## maximum (so it changes no figure a decision reads):
##
## * `store`: the daemon has an estimate store, as in production;
## * `no-store`: the same daemon started with `--estimate-db ""`, which keeps
##   the learned rows in memory only. It learns from every finish exactly as
##   the other arm does; only the durable write is absent.
##
## So the difference between the arms is the writer's cost and nothing else
## (`--no-block` adds a third arm with no block and no learning at all).
##
## The figure is the daemon process's own CPU (`utime + stime` from
## `/proc/<pid>/stat`, every thread, the writer included) over the loop and a
## settle period long enough for the writer's 50 ms drain to run dry,
## divided by the number of finishes. It includes the idle daemon's own CPU
## over the loop, the same in every arm. `/proc` counts in clock ticks
## (printed; 10 ms on a usual Linux), so the resolution per finish is one
## tick divided by `--finishes`: 5 us at the default 2000. Linux only.
##
## WHAT THE PACING MODELS. The writer coalesces the queued rows of one key,
## so an unpaced loop (`--pace-ms=0`) sends any number of finishes into one
## commit per 50 ms drain. `--pace-ms=60` (the default) puts each finish in a
## drain of its own: ONE KEY REPEATING within the refresh interval, as the
## overhead gate's rounds repeat their actions. That is the case a refresh
## interval saves on. A build whose actions all have distinct command ids
## commits each one once either way and gets no saving from it.
##
## Usage (from the repository root, after `just build`):
##   nim c -d:release -r benchmarks/lib/runquota_finish_learning_bench.nim \
##     [--finishes=2000] [--pace-ms=60] [--no-block] [--repeat=4] [--verbose]
##
## Rounds alternate the arm order (A B, then B A, ...), so a drift in the
## host's load over the run falls on both arms alike; the summary gives each
## arm's mean and spread (min..max) and the difference of the means.

when not defined(linux):
  {.error: "runquota_finish_learning_bench reads /proc and runs on Linux only".}

import std/[math, os, osproc, parseopt, posix, strutils, times]

import runquota_client
import runquota_protocol
import rqm_daemon

const
  StatsKey = "finish-learning-bench"
  SettleMillis = 1_000
    ## Long enough for the writer (50 ms cadence) to drain what the loop
    ## queued, so its CPU is counted in the arm that caused it.

type Arm = enum
  armStore = "store"
  armNoStore = "no-store"
  armNoBlock = "no-block"

proc clockTicks(): float =
  float(sysconf(SC_CLK_TCK))

proc processCpuSeconds(pid: int): float =
  ## `utime + stime` of the whole process, every thread. The command field
  ## may hold spaces, so the fields are counted after its closing `)`.
  let text = readFile("/proc/" & $pid & "/stat")
  let fields = text[text.rfind(')') + 2 .. ^1].splitWhitespace()
  # After the `)`: state is field 3, so utime (14) and stime (15) are at
  # 11 and 12 here.
  (parseFloat(fields[11]) + parseFloat(fields[12])) / clockTicks()

proc startDaemon(arm: Arm): RqmDaemon =
  ## `startRqmDaemon`, with `--estimate-db ""` (a later argument wins) for
  ## the arm without a store.
  if arm != armNoStore:
    return startRqmDaemon("rqbench")
  result.root = scratchDir("rqbench")
  result.socket = result.root / "d.sock"
  writeFile(result.root / "host.toml", hostFileText())
  result.process = launch(result.root, result.socket,
    privateEnv(result.socket), ["--estimate-db", ""])
  if not awaitSocket(result.process, result.socket):
    stopOwned(result.process)
    quit("runquotad did not bind", 1)
  putEnv("RUNQUOTA_ENDPOINT_SCOPE", "private")
  putEnv("RUNQUOTA_SOCKET", result.socket)

proc runArm(arm: Arm; finishes, paceMillis: int; verbose: bool): float =
  ## Daemon CPU seconds per finish for one arm, on a fresh daemon.
  let daemon = startDaemon(arm)
  defer: daemon.stop()
  let pid = daemon.process.processID
  var client = connectDefault()
  defer: client.close()
  var session = client.registerSession(SessionName, "0")
  const maxPeak = 4'u64 * GiB
  # THE MAXIMUM FIRST, so every timed finish's peak is below it.
  var first = session.requestLease(request(StatsKey, 1'u64 * GiB))
  first.finishWith(succeeded(), peakBytes = maxPeak,
    capBlock = measured(first.memoryCap.capBytes, maxPeak,
      first.memoryCap.basis))
  sleep(SettleMillis)
  let before = processCpuSeconds(pid)
  let started = epochTime()
  var next = started
  for i in 0 ..< finishes:
    var lease = session.requestLease(request(StatsKey, 1'u64 * GiB))
    if arm == armNoBlock:
      lease.finishWith(succeeded())
    else:
      let peak = 1'u64 * GiB + uint64(i mod 997) * MiB
      lease.finishWith(succeeded(), peakBytes = peak,
        capBlock = measured(lease.memoryCap.capBytes, peak,
          lease.memoryCap.basis))
    if paceMillis > 0:
      next += float(paceMillis) / 1000.0
      let wait = next - epochTime()
      if wait > 0: sleep(int(wait * 1000))
  let elapsed = epochTime() - started
  sleep(SettleMillis)
  let after = processCpuSeconds(pid)
  if verbose:
    echo "  ", arm, ": loop ", formatFloat(elapsed, ffDecimal, 1),
      " s, daemon CPU ", formatFloat(after - before, ffDecimal, 3),
      " s, sample_count ", client.learnedRow(StatsKey).figure("sample_count")
  session.closeSession()
  (after - before) / float(finishes)

proc main() =
  var finishes = 2000
  var repeat = 4
  var paceMillis = 60
  var verbose = false
  var arms = @[armStore, armNoStore]
  for kind, key, value in getopt():
    case key
    of "finishes": finishes = parseInt(value)
    of "repeat": repeat = parseInt(value)
    of "pace-ms": paceMillis = parseInt(value)
    of "verbose": verbose = true
    of "no-block": arms.add(armNoBlock)
    else: quit("unknown option " & key, 2)
  let tick = 1.0 / clockTicks()
  echo "clock tick ", formatFloat(tick * 1000, ffDecimal, 1),
    " ms; resolution per finish ",
    formatFloat(tick / float(finishes) * 1e6, ffDecimal, 1), " us"
  var results: array[Arm, seq[float]]
  for r in 0 ..< repeat:
    # ABBA: every other round runs the arms in reverse order.
    var order = arms
    if r mod 2 == 1:
      order = @[]
      for i in countdown(arms.high, 0): order.add(arms[i])
    for arm in order:
      let perFinish = runArm(arm, finishes, paceMillis, verbose) * 1e6
      results[arm].add(perFinish)
      echo alignLeft($arm, 9), " round ", r, ": daemon CPU per finish = ",
        formatFloat(perFinish, ffDecimal, 1), " us (", finishes,
        " finishes, ", paceMillis, " ms apart)"
  proc us(x: float): string = formatFloat(x, ffDecimal, 1)
  proc mean(values: seq[float]): float = sum(values) / float(values.len)
  for arm in arms:
    let values = results[arm]
    echo "summary ", alignLeft($arm, 9), ": mean ", us(mean(values)),
      " us, spread ", us(min(values)), "..", us(max(values)), " us over ",
      values.len, " rounds"
  echo "summary store - no-store: ",
    us(mean(results[armStore]) - mean(results[armNoStore])), " us per finish"

main()
