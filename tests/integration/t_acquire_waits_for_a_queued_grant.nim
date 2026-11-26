## `runquota acquire` waits for a grant that is queued, then runs the command.
##
## reprobuild-pm spec/RunQuota-Protocol-And-Client-Libraries.md: `runquota
## acquire` "requests a lease, starts the command after grant", and § What A
## Budget Refusal Says: a request that does not fit *right now* "is a queue and
## not a refusal". The CLI used to wait only for `--benchmark`: every other
## request that had to queue printed "waiting for resource budget" and exited
## 1 without running its command, so a shell script could not use `acquire` to
## bound its own parallelism -- the second of two checks on a one-slot budget
## simply failed. reprobuild's `just lint` leases each of its `nim check` runs
## through `acquire` (reprobuild-pm issue
## 2026-11-26-the-pre-commit-just-lint-runs-nproc-parallel-nim-checks-outside-
## runquota-and-takes-a-shared-host-to-5-gb-free), which is how this was found.
##
## NO MOCKS. The shipped CLI, a real private `runquotad` on a scratch socket
## with a one-CPU-slot budget, and real child processes (`/bin/sh`). The
## isolation is `private_daemon_fixture`'s: a fresh 0700 directory, the
## private endpoint policy, and only the daemon this file started is stopped.

when defined(posix):
  import std/[os, osproc, streams, strtabs, strutils, times, unittest]

  import daemon_binary
  import private_daemon_fixture

  type Started = tuple[process: Process, at: float]

  proc startAcquire(env: StringTableRef; args: openArray[string]): Started =
    (startProcess(cliPath(), env = env, args = args,
      options = {poStdErrToStdOut}), epochTime())

  proc finish(started: Started): tuple[code: int, output: string, at: float] =
    let text = started.process.outputStream.readAll()
    let code = started.process.waitForExit()
    started.process.close()
    (code, text, epochTime())

  let root = scratchDir("rqacqwait")
  let socket = root / "d.sock"
  let env = privateEnv(socket)
  # One CPU slot: a second one-slot lease can only queue behind the first.
  let daemon = launchOwned(root, socket, env,
    daemonArgs(root, socket, ["--cpu-milli", "1000",
      "--memory-bytes", $(8'u64 * 1024 * 1024 * 1024)]))

  suite "runquota acquire waits for a queued grant":
    test "a second acquire on a full budget waits, then runs its command":
      let marker = root / "first-ended"
      # The first holds the only slot for a second and a half, and records
      # when it is done.
      let first = startAcquire(env, ["acquire", "--cpu", "1000",
        "--mem", "64MiB", "--label", "holder", "--",
        "/bin/sh", "-c", "sleep 1.5; touch '" & marker & "'; echo first-done"])
      # Wait until the daemon has granted it, so the second cannot win.
      var held = false
      for _ in 0 ..< 400:
        let leases = cli(env, ["leases", "--json"])
        if "holder" in leases.output:
          held = true
          break
        sleep(25)
      check held
      # The second asks while the slot is held. Its command records whether
      # the first had finished when it started.
      let second = startAcquire(env, ["acquire", "--cpu", "1000",
        "--mem", "64MiB", "--label", "waiter", "--",
        "/bin/sh", "-c", "if [ -e '" & marker & "' ]; then echo " &
          "started-after-first; else echo started-while-held; fi"])
      let secondDone = finish(second)
      let firstDone = finish(first)
      checkpoint "second: exit " & $secondDone.code & ": " & secondDone.output
      checkpoint "first: exit " & $firstDone.code & ": " & firstDone.output
      check firstDone.code == 0
      check "first-done" in firstDone.output
      # The defect: exit 1 with "waiting for resource budget" and no run.
      check secondDone.code == 0
      check "started-after-first" in secondDone.output
      check "started-while-held" notin secondDone.output

    test "a queued acquire still reports its command's exit status":
      let first = startAcquire(env, ["acquire", "--cpu", "1000",
        "--mem", "64MiB", "--label", "holder2", "--", "/bin/sh", "-c", "sleep 1"])
      var held = false
      for _ in 0 ..< 400:
        if "holder2" in cli(env, ["leases", "--json"]).output:
          held = true
          break
        sleep(25)
      check held
      let second = finish(startAcquire(env, ["acquire", "--cpu", "1000",
        "--mem", "64MiB", "--", "/bin/sh", "-c", "exit 7"]))
      discard finish(first)
      check second.code == 7

    test "a request that can never fit is still refused at once, not queued":
      # Two slots on a one-slot budget: a budget refusal, which names the
      # amounts (§ What A Budget Refusal Says), and the command never runs.
      let refused = finish(startAcquire(env, ["acquire", "--cpu", "2000",
        "--mem", "64MiB", "--", "/bin/sh", "-c", "echo ran"]))
      checkpoint refused.output
      check refused.code == 1
      check "ran" notin refused.output.splitLines()
      check "exceeds machine CPU budget" in refused.output

    test "the no-command form waits for a queued grant too":
      let first = startAcquire(env, ["acquire", "--cpu", "1000",
        "--mem", "64MiB", "--label", "holder3", "--", "/bin/sh", "-c", "sleep 1"])
      var held = false
      for _ in 0 ..< 400:
        if "holder3" in cli(env, ["leases", "--json"]).output:
          held = true
          break
        sleep(25)
      check held
      let second = finish(startAcquire(env, ["acquire", "--cpu", "1000",
        "--mem", "64MiB"]))
      discard finish(first)
      checkpoint second.output
      check second.code == 0
      check "granted" in second.output

  stopOwned(daemon)
  removeDir(root)
