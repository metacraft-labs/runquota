## A daemon whose endpoint file system has no room for the published
## aggregate table serves without the table, and says why on its listening
## line.
##
## THE PROPERTY. The published table is a cache: the socket answers everything
## it can, so a daemon that cannot publish serves exactly as before
## (reprobuild-pm `spec/RunQuota-Shared-Memory-Structures.md`, "The published
## aggregate table"). A file system that is full, or on which the daemon's
## user is over quota, is one way of not being able to publish, and it must
## end the same way as any other: the daemon listens, answers a client, and
## its listening line names the file and the errno.
##
## WHAT IT USED TO DO. The publisher sized the table with `ftruncate`, which
## only moves the end of file, mapped it, and stored the header through the
## mapping. On a full file system that first store is a page fault nothing
## can back, and the kernel delivers SIGBUS: the daemon died after binding
## its socket and before its listening line, with an empty log (reprobuild-pm
## `issues/2026-11-19-per-user-runquotad-dies-with-sigbus-and-an-empty-log-when-its-endpoint-filesystem-is-over-quota.md`).
## The blocks are now allocated before the file is mapped, where a refusal is
## an errno.
##
## THE FILE SYSTEM IS REAL. The shipped `runquotad` runs with its socket on a
## 256 KiB tmpfs that a filler file has taken every block of, mounted in a
## mount namespace of the test's own (`unshare --user --map-root-user
## --mount`), so nothing outside the test can see or fill it. The namespace is
## a pid namespace too, so whatever the harness started ends with it. The
## second case
## is the control: the same harness and the same mount without the filler
## publishes the table, so the first case's refusal is the full file system's
## doing and not the harness's.
##
## WHAT IT DOES NOT REACH. The daemon's output is read from a file on an
## ordinary file system. A log file on the SAME full file system stays empty
## whatever the daemon says, because nothing can be written there; and the
## refusal exercised is `ENOSPC`, not a per-user quota's `EDQUOT`, which
## needs a tmpfs mounted with quotas by real root.
##
## No mocks. Every process is one this file started. Linux only (the mount
## namespace and tmpfs's size limit); elsewhere every case is reported
## skipped. A host that does not allow unprivileged user namespaces fails the
## prerequisite loudly, as `t_foreign_namespace_client` does.

const CaseNames = [
  "a daemon on a full endpoint file system serves and says why it publishes no table",
  "the same daemon on the same file system with room publishes its table"]

when not defined(linux):
  import std/unittest
  suite "stats_table_on_a_full_filesystem":
    for name in CaseNames:
      test name:
        skip()
else:
  import std/[os, osproc, posix, streams, strutils, unittest]

  import daemon_binary
  import private_daemon_fixture

  const Harness = """
set -u
root=$1; out=$2; daemon=$3; cli=$4; fill=$5
mount -t tmpfs -o size=256k,mode=0700 tmpfs "$root" || exit 90
if [ "$fill" = full ]; then
  # Until the file system refuses: dd's failure IS the wanted outcome.
  dd if=/dev/zero of="$root/fill" bs=4096 2>/dev/null
  # ...and it must really be full: one more byte has nowhere to go.
  dd if=/dev/zero of="$root/probe" bs=1 count=1 2>/dev/null
  if [ -s "$root/probe" ]; then exit 91; fi
  rm -f "$root/probe"
fi
"$daemon" --socket "$root/d.sock" \
  --host-config "$out/host.toml" --host-identity-file "$out/host-id" \
  --estimate-db "$out/est.sqlite" --no-write-stats \
  --ambient-sample-interval-millis 0 --memory-pressure-source unavailable \
  --cpu-pressure-file "$out/cpu-pressure" > "$out/daemon.out" 2>&1 &
pid=$!
i=0
while ! grep -q "runquotad listening" "$out/daemon.out" 2>/dev/null \
    && kill -0 "$pid" 2>/dev/null && [ "$i" -lt 600 ]; do
  sleep 0.05; i=$((i + 1))
done
"$cli" status --json > "$out/cli.out" 2>&1
echo $? > "$out/cli.code"
ls -A "$root" > "$out/listing"
kill -TERM "$pid" 2>/dev/null
# A daemon that does not stop is killed, and its code (137) fails the case:
# `wait` alone would sit here until the runner's bound.
( i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 600 ]; do
    sleep 0.05; i=$((i + 1))
  done
  kill -KILL "$pid" 2>/dev/null ) &
wait "$pid"
echo $? > "$out/daemon.code"
exit 0
"""

  type Outcome = object
    harnessCode: int
    harnessOutput: string
    daemonCode: string
    daemonOutput: string
    cliCode: string
    cliOutput: string
    listing: seq[string]
    socket: string
    tablePath: string

  let unshareExe = findExe("unshare")

  proc readOr(path: string): string =
    try: readFile(path).strip()
    except IOError, OSError: "<no " & extractFilename(path) & ">"

  proc runOn(fill: string): Outcome =
    ## One daemon on one private tmpfs. `root` is the mount point (and so
    ## short: the socket path has to fit `sun_path`); `outDir` is on the
    ## ordinary scratch file system, where the harness leaves what it saw.
    let root = scratchDir("rqfull")
    let outDir = scratchDir("rqfullout")
    defer:
      removeDir(root)
      removeDir(outDir)
    result.socket = root / "d.sock"
    result.tablePath = root / "stats-table"
    let p = startProcess(unshareExe, env = privateEnv(result.socket),
      args = ["--user", "--map-root-user", "--mount", "--pid", "--fork",
        "--kill-child", "--mount-proc", "sh", "-c", Harness, "sh", root, outDir, daemonPath(), cliPath(), fill],
      options = {poStdErrToStdOut})
    result.harnessOutput = p.outputStream.readAll()
    result.harnessCode = p.waitForExit()
    p.close()
    result.daemonCode = readOr(outDir / "daemon.code")
    result.daemonOutput = readOr(outDir / "daemon.out")
    result.cliCode = readOr(outDir / "cli.code")
    result.cliOutput = readOr(outDir / "cli.out")
    result.listing = readOr(outDir / "listing").splitLines()

  proc listeningLine(o: Outcome): string =
    for line in o.daemonOutput.splitLines():
      if line.startsWith("runquotad listening"): return line
    ""

  suite "stats_table_on_a_full_filesystem":
    prerequisite unshareExe.len > 0, "no unshare on PATH"
    block probe:
      let p = startProcess(unshareExe,
        args = ["--user", "--map-root-user", "--mount", "--pid", "--fork",
          "--kill-child", "--mount-proc", "true"],
        options = {poStdErrToStdOut})
      let output = p.outputStream.readAll()
      let code = p.waitForExit()
      p.close()
      prerequisite code == 0,
        "unprivileged user, mount and pid namespaces are not available: " &
          output

    # The control runs first: what an orderly stop of a healthy daemon looks
    # like here is what the full case is compared against.
    let roomy = runOn("room")
    let full = runOn("full")

    test CaseNames[0]:
      checkpoint "harness: " & $full.harnessCode & " " & full.harnessOutput
      checkpoint "daemon exit: " & full.daemonCode
      checkpoint "daemon output: " & full.daemonOutput
      checkpoint "client: " & full.cliCode & " " & full.cliOutput
      # 90: the tmpfs could not be mounted. 91: the filler left room.
      check full.harnessCode == 0
      # NOT 135 (128 + SIGBUS): the daemon was still there to be stopped, and
      # stopped the way the healthy one did.
      check full.daemonCode == roomy.daemonCode
      check full.daemonCode != $(128 + int(SIGBUS))
      # It served: a client was answered over the socket.
      check full.cliCode == "0"
      # And it said why there is no table, on the line readers already read:
      # the file and the errno.
      let line = full.listeningLine
      check "published stats table: not publishing (cannot allocate" in line
      check full.tablePath in line
      check $strerror(ENOSPC) in line
      check "socket remains authoritative" in line
      # Nothing half-made is left where a reader would look for the table.
      for entry in full.listing:
        check not entry.startsWith("stats-table")

    test CaseNames[1]:
      checkpoint "harness: " & $roomy.harnessCode & " " & roomy.harnessOutput
      checkpoint "daemon exit: " & roomy.daemonCode
      checkpoint "daemon output: " & roomy.daemonOutput
      checkpoint "client: " & roomy.cliCode & " " & roomy.cliOutput
      check roomy.harnessCode == 0
      check roomy.cliCode == "0"
      check ("published stats table: " & roomy.tablePath & " slots=") in
        roomy.listeningLine
      check "stats-table" in roomy.listing
