## M10 gate: host identity and versioned hardware profiles.
##
## No mocks. Every assertion below runs against a real SQLite database in
## a temporary directory, through the same entry points the daemon calls,
## and the "unchanged hardware" arm uses the machine this test is running
## on rather than a fixture — a detector that only ever describes a
## constant cannot be shown to be stable.
##
## A hardware change is simulated by *injecting* values, not by finding
## another machine: `detectHardwareProfile` returns a value, and the
## reconciliation under test takes a value, so a machine with 2x the RAM,
## 8 more cores and a spinning disk is one struct away. That is the whole
## reason detection and reconciliation are separate procedures.
##
## The two clauses most at risk of being vacuous are handled explicitly:
##
## * "existing execution rows continue to reference the OLD profile" is
##   worthless unless the hardware really changed in between, so the
##   execution is written first, the change is applied second, and the
##   old profile row is re-read and checked to still describe the OLD
##   hardware — not merely to still exist.
## * "`host_id` is not derived from the hostname" cannot be proven by a
##   substring check alone. On this host the name is short and the id is
##   hex, so containment can only ever catch a literal-name derivation and
##   would say nothing about `sha256(hostname)`. The assertion that does
##   the work is therefore a differential: many independent identities
##   minted on ONE machine, with ONE hostname, must all differ. Every
##   deterministic function of the machine's name, address or hardware
##   fails that, and randomness passes it.

import std/[nativesockets, options, os, sequtils, strutils, unittest]

import runquota_observation_store

proc scratchDir(name: string): string =
  result = getTempDir() / ("runquota-m10-" & name & "-" &
    $getCurrentProcessId())
  removeDir(result)
  createDir(result)

proc profileById(store: ObservationStore; profileId: string): HostProfileRow =
  for row in store.readHostProfiles():
    if row.profileId == profileId:
      return row
  doAssert false, "no host_profiles row with profile_id " & profileId

proc currentProfileCount(store: ObservationStore): int =
  for row in store.readHostProfiles():
    if row.validToUnixMillis.isNone:
      result += 1

proc changedHardware(base: HardwareProfile): HardwareProfile =
  ## The machine gains RAM and cores and loses its NVMe — the three fields
  ## the gate names, changed at once so that a reconciliation keying on
  ## only one of them still has to notice.
  result = base
  result.ramBytes = base.ramBytes * 2
  result.physicalCores = base.physicalCores + 8
  result.logicalCores = base.logicalCores + 8
  result.diskClass = if base.diskClass == dcHdd: dcSsd else: dcHdd

suite "observation_store_host_profile":

  test "the profile hash matches the published SHA-256 vectors":
    # `profile_hash` is only useful if it is the hash it claims to be. A
    # digest compared solely against itself agrees with itself while being
    # wrong, and the wrongness surfaces the day two machines' databases
    # are merged.
    check sha256Hex("") ==
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    check sha256Hex("abc") ==
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    check sha256Hex(
        "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq") ==
      "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
    check sha256Hex("a".repeat(1_000_000)) ==
      "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"

  test "the hash covers every descriptive column and nothing else":
    # A field left out of the encoding is a hardware change the store
    # cannot see. Each one is perturbed on its own and must move the hash.
    let base = detectHardwareProfile()
    let baseHash = profileHash(base)

    var mutated: seq[HardwareProfile] = @[]
    for value in ["other-cpu"]:
      var m = base; m.cpuModel = value; mutated.add(m)
    block:
      var m = base; m.physicalCores = base.physicalCores + 1; mutated.add(m)
      m = base; m.logicalCores = base.logicalCores + 1; mutated.add(m)
      m = base; m.ramBytes = base.ramBytes + 1; mutated.add(m)
      m = base; m.swapBytes = base.swapBytes + 1; mutated.add(m)
      m = base
      m.diskClass = if base.diskClass == dcHdd: dcSsd else: dcHdd
      mutated.add(m)
      m = base; m.fsType = base.fsType & "x"; mutated.add(m)
      m = base; m.arch = base.arch & "x"; mutated.add(m)
      m = base; m.os = base.os & "x"; mutated.add(m)
      m = base; m.osVersion = base.osVersion & "x"; mutated.add(m)
      m = base; m.kernelVersion = base.kernelVersion & "x"; mutated.add(m)
      m = base; m.virtualization = base.virtualization & "x"; mutated.add(m)
      m = base; m.cpuShareGroup = base.cpuShareGroup & "x"; mutated.add(m)

    check mutated.len == 13
    var hashes = @[baseHash]
    for m in mutated:
      let hash = profileHash(m)
      check hash != baseHash
      check hash notin hashes
      hashes.add(hash)

    # And the encoding cannot be forged by moving a string across a field
    # boundary, which is what the length prefixes are for.
    var shifted = base
    shifted.arch = base.arch & "\nos=" & $base.os.len & ":" & base.os
    shifted.os = ""
    check profileHash(shifted) != baseHash

  test "detection twice in a row describes the same machine":
    # If any field moved on its own, `ensureHostProfile` would open a
    # fresh profile on every daemon start and the table would grow without
    # bound. This is where a utilisation figure smuggled in as a capacity
    # gets caught.
    let first = detectHardwareProfile(getTempDir())
    let second = detectHardwareProfile(getTempDir())
    check first == second
    check profileHash(first) == profileHash(second)

    # And detection actually detected something: an all-`unknown` profile
    # is stable too, and would make every assertion above vacuous.
    check first.cpuModel != unknownField
    check first.arch != unknownField
    check first.os != unknownField
    check first.osVersion != unknownField
    check first.kernelVersion != unknownField
    check first.virtualization in ["bare-metal", "vm", "container"]
    check first.fsType != unknownField
    check first.diskClass != dcUnknown
    # `logicalCores >= 1`, `physicalCores >= 1` and `swapBytes >= 0` are
    # deliberately NOT asserted here: `detectHardwareProfile` floors the two
    # core counts at 1 and `quantizeSwapBytes` floors swap at 0, so all three
    # hold by construction and no mutation of the detector can make them
    # fail. Assert the counts against each other instead, which a detector
    # that reported logical cores as physical ones would still satisfy but a
    # transposed or truncated read would not.
    check first.logicalCores >= first.physicalCores
    check first.ramBytes > 0
    check profileHash(first).startsWith("sha256:")
    check profileHash(first).len == "sha256:".len + 64

  test "swap is quantized to whole GiB before it is stored and hashed":
    # THE QUANTIZER HAD NO FALSIFIABLE COVERAGE. Verification deleted it --
    # made `quantizeSwapBytes` the identity -- and the entire suite stayed
    # GREEN, because swap on this host is 0 and 0 is a fixed point. So the
    # one design decision the milestone record singles out for a second
    # opinion was the one nothing could have caught. It is a pure function,
    # so the fix is a table.
    const gib = 1024'i64 * 1024'i64 * 1024'i64
    check quantizeSwapBytes(0) == 0
    check quantizeSwapBytes(-5) == 0          # never a negative capacity
    check quantizeSwapBytes(1) == 0
    check quantizeSwapBytes(gib div 2 - 1) == 0
    check quantizeSwapBytes(gib div 2) == gib # rounds to NEAREST, not down
    check quantizeSwapBytes(gib - 1) == gib
    check quantizeSwapBytes(gib) == gib
    check quantizeSwapBytes(gib + gib div 2 - 1) == gib
    check quantizeSwapBytes(gib * 3 + 1) == gib * 3
    for raw in [0'i64, 1, gib div 3, gib, gib * 7 + 12345]:
      check quantizeSwapBytes(raw) mod gib == 0

    # The point of quantizing: two byte-different swap readings inside one
    # GiB are the same hardware and MUST NOT fork the profile. This is the
    # assertion the macOS dynamic pager makes necessary -- `vm.swapusage`
    # reports utilisation, so a byte-exact figure would open a new profile
    # every time the pager grew a file.
    let base = detectHardwareProfile(getTempDir())
    var grown = base
    grown.swapBytes = quantizeSwapBytes(3_500_000_000'i64)
    var grownMore = base
    grownMore.swapBytes = quantizeSwapBytes(3_600_000_000'i64)
    check grown.swapBytes == grownMore.swapBytes
    check profileHash(grown) == profileHash(grownMore)

    # And the residual is real rather than hidden: crossing a GiB boundary
    # DOES fork the profile, so the quantization bounds the churn without
    # removing it (M10 `:deferred:` (2)).
    var crossed = base
    crossed.swapBytes = quantizeSwapBytes(4_400_000_000'i64)
    check crossed.swapBytes != grown.swapBytes
    check profileHash(crossed) != profileHash(grown)

  test "unchanged hardware reuses the profile row across many starts":
    let dir = scratchDir("reuse")
    defer: removeDir(dir)
    let store = openObservationStore(dir / "observations.sqlite")
    check store.captureEnabled

    let hostId = resolveHostIdentity(dir / "host-id").hostId
    let hardware = detectHardwareProfile(dir)

    var profileIds: seq[string] = @[]
    for start in 0 ..< 8:
      # Each iteration is a daemon start over the same store.
      check store.ensureHostRow(hostId, "boot-" & $start)
      profileIds.add(store.ensureHostProfile(hostId, hardware))

    check profileIds.len == 8
    check profileIds[0].len > 0
    check profileIds.allIt(it == profileIds[0])

    # No accumulation, in either table.
    let profiles = store.readHostProfiles()
    check profiles.len == 1
    check profiles[0].profileId == profileIds[0]
    check profiles[0].validToUnixMillis.isNone
    check profiles[0].profileHash == profileHash(hardware)
    check profiles[0].hostId == hostId
    check hardwareProfile(profiles[0]) == hardware

    let hosts = store.readHosts()
    check hosts.len == 1
    check hosts[0].hostId == hostId
    # The host row is refreshed rather than duplicated: it records the
    # machine, and the machine rebooted seven times.
    check hosts[0].lastBootId == "boot-7"

  test "a hardware change opens a new profile and bounds the old one":
    let dir = scratchDir("change")
    defer: removeDir(dir)
    let store = openObservationStore(dir / "observations.sqlite")
    check store.captureEnabled
    let hostId = resolveHostIdentity(dir / "host-id").hostId
    check store.ensureHostRow(hostId, "boot-0")

    let generationOne = detectHardwareProfile(dir)
    let generationTwo = changedHardware(generationOne)
    var generationThree = generationTwo
    generationThree.cpuModel = generationTwo.cpuModel & " (replaced)"

    let t1 = 1_700_000_000_000'i64
    let t2 = t1 + 3_600_000
    let t3 = t2 + 86_400_000

    let id1 = store.ensureHostProfile(hostId, generationOne, t1)
    # An unchanged re-detection between the two changes must not open a
    # row, or "no accumulation" would only hold for a store nobody
    # restarted.
    check store.ensureHostProfile(hostId, generationOne, t1 + 1) == id1
    let id2 = store.ensureHostProfile(hostId, generationTwo, t2)
    check store.ensureHostProfile(hostId, generationTwo, t2 + 1) == id2
    let id3 = store.ensureHostProfile(hostId, generationThree, t3)

    check id1.len > 0
    check id1 != id2
    check id2 != id3
    check id1 != id3

    let profiles = store.readHostProfiles()
    check profiles.len == 3
    check currentProfileCount(store) == 1

    let first = profileById(store, id1)
    let second = profileById(store, id2)
    let third = profileById(store, id3)

    # Bounded: each interval closes exactly where the next one opens, so
    # an execution at any instant has exactly one profile and never two.
    check first.validFromUnixMillis == t1
    check first.validToUnixMillis == some(t2)
    check second.validFromUnixMillis == t2
    check second.validToUnixMillis == some(t3)
    check third.validFromUnixMillis == t3
    check third.validToUnixMillis.isNone
    check first.validToUnixMillis.get == second.validFromUnixMillis
    check second.validToUnixMillis.get == third.validFromUnixMillis
    check first.validFromUnixMillis < first.validToUnixMillis.get
    check second.validFromUnixMillis < second.validToUnixMillis.get

    # The superseded rows still describe the hardware they described.
    check hardwareProfile(first) == generationOne
    check hardwareProfile(second) == generationTwo
    check hardwareProfile(third) == generationThree
    check first.ramBytes == generationOne.ramBytes
    check second.ramBytes == generationOne.ramBytes * 2
    check first.profileHash == profileHash(generationOne)
    check second.profileHash == profileHash(generationTwo)
    check third.profileHash == profileHash(generationThree)
    check first.profileHash != second.profileHash

    check store.currentHostProfile(hostId).get.profileId == id3

  test "executions written before a hardware change still name the old profile":
    let dir = scratchDir("history")
    defer: removeDir(dir)
    let store = openObservationStore(dir / "observations.sqlite")
    check store.captureEnabled
    let hostId = resolveHostIdentity(dir / "host-id").hostId
    check store.ensureHostRow(hostId, "boot-0")

    let oldHardware = detectHardwareProfile(dir)
    let newHardware = changedHardware(oldHardware)
    let t1 = 1_700_000_000_000'i64
    let t2 = t1 + 3_600_000

    let oldProfileId = store.ensureHostProfile(hostId, oldHardware, t1)
    check store.insertRun(RunRow(
      runId: "run-1", hostId: hostId, tool: "repro-build",
      toolVersion: "0.1.0", invocationKind: "build",
      startedAtUnixMillis: t1, captureCompleteness: ccComplete,
      droppedObservations: 0))

    proc execution(id, profileId: string; startedAt, finishedAt: int64):
        ExecutionRow =
      ExecutionRow(
        executionId: id, hostId: hostId, hostProfileId: some(profileId),
        runId: "run-1", commandStatsId: "cc-hello", leaseId: some(1'i64),
        startedAtUnixMillis: startedAt, finishedAtUnixMillis: finishedAt,
        durationMillis: finishedAt - startedAt, exitStatus: 0,
        termination: tExited, attempt: 1, retryOf: none(string),
        peakRssBytes: 4096, cpuUserMillis: none(int64),
        cpuSysMillis: none(int64), maxProcesses: 1, majorPageFaults: 0,
        ioReadBytes: none(int64), ioWriteBytes: none(int64),
        captureCompleteness: ccComplete, droppedObservations: 0)

    check store.insertExecution(
      execution("exec-before", oldProfileId, t1 + 1000, t1 + 5000))

    # THE HARDWARE REALLY CHANGES HERE. Without this line every assertion
    # below is satisfied by a store where nothing ever happened.
    let newProfileId = store.ensureHostProfile(hostId, newHardware, t2)
    check newProfileId != oldProfileId

    check store.insertExecution(
      execution("exec-after", newProfileId, t2 + 1000, t2 + 5000))

    let executions = store.readExecutions()
    check executions.len == 2
    var before, after: ExecutionRow
    for row in executions:
      if row.executionId == "exec-before": before = row
      elif row.executionId == "exec-after": after = row
    check before.executionId == "exec-before"
    check after.executionId == "exec-after"

    # The past did not move.
    check before.hostProfileId == some(oldProfileId)
    check after.hostProfileId == some(newProfileId)

    # And the profile the old execution names still describes the hardware
    # that ran it, rather than having been rewritten in place. This is the
    # assertion the whole versioning scheme exists to make true: an
    # in-place update would leave `exec-before` pointing at a row claiming
    # twice the RAM the machine had.
    let oldProfile = profileById(store, oldProfileId)
    check hardwareProfile(oldProfile) == oldHardware
    check oldProfile.ramBytes == oldHardware.ramBytes
    check oldProfile.ramBytes != newHardware.ramBytes
    check oldProfile.profileHash == profileHash(oldHardware)

    # The execution ran inside the window its profile was current for.
    check before.startedAtUnixMillis >= oldProfile.validFromUnixMillis
    check oldProfile.validToUnixMillis.isSome
    check before.finishedAtUnixMillis <= oldProfile.validToUnixMillis.get
    let newProfile = profileById(store, newProfileId)
    check after.startedAtUnixMillis >= newProfile.validFromUnixMillis
    check newProfile.validToUnixMillis.isNone

  test "the schema refuses a second current profile for one host":
    # `ensureHostProfile` reusing the current row is a property of the
    # code; one current profile per host is a property of the database,
    # and holds against a client reaching past this library.
    let dir = scratchDir("unique")
    defer: removeDir(dir)
    let path = dir / "observations.sqlite"
    let store = openObservationStore(path)
    check store.captureEnabled
    let hostId = resolveHostIdentity(dir / "host-id").hostId
    check store.ensureHostRow(hostId, "boot-0")
    discard store.ensureHostProfile(hostId, detectHardwareProfile(dir), 1000)

    proc insertRaw(profileId: string; validTo: string): SqliteOutcome =
      runSqlite(path,
        "insert into host_profiles (host_id, profile_id, profile_hash, " &
        "valid_from_unix_millis, valid_to_unix_millis, cpu_model, " &
        "physical_cores, logical_cores, ram_bytes, swap_bytes, disk_class, " &
        "fs_type, arch, os, os_version, kernel_version, virtualization, " &
        "cpu_share_group) values ('" & hostId & "', '" & profileId &
        "', 'sha256:0', 500, " & validTo & ", 'cpu', 1, 1, 1, 0, 'ssd', " &
        "'apfs', 'arm64', 'darwin', '1', '1', 'bare-metal', 'local');")

    let rejected = insertRaw("profile-second-current", "null")
    check not rejected.ok
    check "UNIQUE" in rejected.error.toUpperAscii
    check store.readHostProfiles().len == 1

    # The positive control: the index constrains *current* profiles only.
    # Without this, an index that forbade every second row would pass the
    # assertion above while making history impossible to record.
    let accepted = insertRaw("profile-superseded", "400")
    check accepted.ok
    check store.readHostProfiles().len == 2
    check currentProfileCount(store) == 1

  test "host_id is machine identity, not a name":
    let dir = scratchDir("identity")
    defer: removeDir(dir)

    # Each simulated machine gets a PROVISIONED state directory, because
    # that is now the precondition: `resolveHostIdentity` mints into a
    # directory the install step made and never creates one itself.
    createDir(dir / "machine-a")
    let first = resolveHostIdentity(dir / "machine-a" / "host-id")
    check first.persisted
    check first.hostId.len > 0
    # Opaque and fixed-shape: `host-` plus 32 lowercase hex digits, so
    # there is no room in it for a name, a domain or an address.
    check isOpaqueId(first.hostId, "host-")
    check first.hostId.len == "host-".len + 32

    # Stable: the same machine reads back the same identity, which is what
    # keeps `hosts` from growing a row per daemon start.
    for _ in 0 ..< 4:
      check resolveHostIdentity(dir / "machine-a" / "host-id").hostId ==
        first.hostId

    # THE LOAD-BEARING ASSERTION. Sixty-four identities minted on ONE
    # machine, under ONE hostname, one MAC address and one set of
    # hardware, must all differ. Every deterministic function of anything
    # the machine knows about itself -- the hostname, a hash of the
    # hostname, the primary interface, the serial number -- collapses this
    # set to a single value. A substring check would catch only the first
    # of those.
    var minted: seq[string] = @[]
    for i in 0 ..< 64:
      createDir(dir / ("machine-" & $i))
      let identity = resolveHostIdentity(dir / ("machine-" & $i) / "host-id")
      check identity.persisted
      check isOpaqueId(identity.hostId, "host-")
      check identity.hostId notin minted
      minted.add(identity.hostId)
    check minted.len == 64
    check deduplicate(minted).len == 64

    # The direct negative, stated with its own limits. `hostName` here is
    # whatever this host is called; if it happens to be spelled entirely
    # in hex digits a random id could contain it by chance, so the check
    # is applied only when the name cannot collide with the id's alphabet.
    # It therefore catches a literal-name derivation and nothing subtler,
    # which is precisely why the differential above exists.
    let hostName = getHostName()
    check hostName.len > 0
    for candidate in [hostName, hostName.toLowerAscii, hostName.toUpperAscii,
                      hostName.split('.')[0]]:
      if candidate.len > 0 and
          not candidate.allIt(it in {'0' .. '9', 'a' .. 'f', 'A' .. 'F'}):
        check candidate notin first.hostId
        for id in minted:
          check candidate notin id

  test "an identity that cannot be persisted is reported, not invented":
    ## THE TWO `hostId.len == 0` ASSERTIONS BELOW WERE INVERTED IN M13c-fix.
    ## They previously read `check isOpaqueId(<x>.hostId, "host-")` -- that
    ## is, they asserted the defect: an id minted for this process and
    ## nothing else. The test's own name says what it should have asserted.
    ## The rule is now normative in
    ## `reprobuild-specs/RunQuota-Observation-Store.md` §"The Execution
    ## Spine": an identity that cannot be persisted is a REFUSAL.
    let dir = scratchDir("nopersist")
    defer: removeDir(dir)

    # A file where a directory would have to be. The state directory is
    # provisioned by installation and never created here, so this is a
    # refusal; OS-4 says the daemon carries on serving leases regardless.
    let blocker = dir / "blocked"
    writeFile(blocker, "not a directory\n")
    let identity = resolveHostIdentity(blocker / "runquota" / "host-id")
    check not identity.persisted
    check identity.hostId.len == 0
    check "cannot persist" in identity.report
    check readFile(blocker) == "not a directory\n"

    # A file that is not ours is left exactly as it was rather than
    # clobbered to make this start tidy.
    let foreign = dir / "someone-elses-file"
    writeFile(foreign, "important\n")
    let second = resolveHostIdentity(foreign)
    check not second.persisted
    check second.hostId.len == 0
    check readFile(foreign) == "important\n"
    check "left alone" in second.report

  test "a store that will not open reports no host and no profile":
    # OS-4 on this path too: identity and profile writes are attempted
    # only behind `captureEnabled`, and refuse rather than raise.
    let dir = scratchDir("degraded")
    defer: removeDir(dir)
    let path = dir / "observations.sqlite"
    block:
      let healthy = openObservationStore(path)
      check healthy.captureEnabled
    let data = readFile(path)
    check data.len > 4096
    writeFile(path, data[0 ..< data.len div 2])

    let store = openObservationStore(path)
    check store.status == ssCorrupt
    check not store.captureEnabled
    check not store.ensureHostRow("host-" & "0".repeat(32), "boot-0")
    check store.ensureHostProfile("host-" & "0".repeat(32),
      detectHardwareProfile(dir)) == ""
    check store.currentHostProfile("host-" & "0".repeat(32)).isNone
