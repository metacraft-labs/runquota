## A memory cap that applies but that the platform layer did not enforce is
## SAID by every CLI launcher, never silent.
##
## Where a platform cannot put the cap in place (Windows has no mechanism
## yet; Linux needs a cgroup root, which the suite leaves off), a launch asked
## to apply a cap runs uncapped. macOS arms its own tracker for every capped
## launch, so there the cap IS applied and nothing is said. That must be visible: `runquota run`,
## `acquire -- CMD` and `jobserver` print `memory cap not enforced: <why>` on
## stderr as the command starts, as an unenforceable `--cap` does, and the
## command still runs. `RUNQUOTA_MEMORY_CAP=1G` makes a cap apply with no
## host file; with the variable unset and the host file's cap off, nothing
## applies and nothing is said.
##
## Falsifying mutation: `memoryCapNotEnforced` answering "" -- every launcher
## then runs the uncapped tree with nothing said.
##
## No mocks: the built `runquotad` and `runquota`, real commands.

when defined(posix):
  import std/[strtabs, strutils, unittest]

  import rqm_daemon

  proc withCap(daemon: RqmDaemon; value: string): StringTableRef =
    result = privateEnv(daemon.socket)
    if value.len > 0:
      result["RUNQUOTA_MEMORY_CAP"] = value
    else:
      result.del("RUNQUOTA_MEMORY_CAP")
    # The suite's default, stated: no cgroup root, so Linux cannot place the
    # cap either.
    result["RUNQUOTA_CGROUP_ROOT"] = "off"

  suite "a cap that is not enforced is said":
    test "run, acquire and jobserver say so, and the command still runs":
      let daemon = startRqmDaemon("rqmnote")
      defer: daemon.stop()
      for (verb, args) in [
          ("run", @["run", "--", "/bin/sh", "-c", "echo ran"]),
          ("acquire", @["acquire", "--cpu", "1000", "--mem", "64MiB", "--",
            "/bin/sh", "-c", "echo ran"]),
          ("jobserver", @["jobserver", "--", "/bin/sh", "-c", "echo ran"])]:
        checkpoint(verb)
        let capped = cli(daemon.withCap("1G"), args)
        checkpoint(capped.output)
        check capped.code == 0
        check "ran" in capped.output
        when defined(macosx):
          check "memory cap not" notin capped.output
        else:
          check "runquota " & verb & ": memory cap not enforced: " in
            capped.output
        let uncapped = cli(daemon.withCap(""), args)
        checkpoint(uncapped.output)
        check uncapped.code == 0
        check "memory cap not" notin uncapped.output
