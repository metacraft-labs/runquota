## Where a tree is placed when its launcher runs under a limited cgroup: the
## pure rules of `resolveCgroupRoot` over a made-up cgroup hierarchy.
##
## THE RULE. With placement on, the launcher reads the limits on its own
## cgroup and each ancestor up to, not including, the deepest cgroup the
## candidate root (the default `runquota.slice`, or `RUNQUOTA_CGROUP_ROOT`)
## also lies in: a `memory.max`, `memory.high` or `memory.swap.max` other than
## `max`, a `cpu.max` with a quota, or a `pids.max` below systemd's default
## per-unit task limit. A limited cgroup whose directory name equals
## `RUNQUOTA_AGENT_SESSION_SCOPE` is the agent session's scope, which a tree
## may leave. With no other limited cgroup the candidate root is used.
## Otherwise the deepest other limited cgroup L holds the tree: the root is
## `L/runquota` when the systemd unit L is (or lies in) is delegated, and
## placement is refused, naming L, its limit and `-p Delegate=yes`, when it
## is not. Delegation is systemd's: its own `user.delegate` /
## `trusted.delegate` mark, RunQuota's record of an earlier answer, or
## (once) the manager's answer to `systemctl show -p Delegate`; this test
## answers it from a table.
##
## WHAT IS GUARDED, each with the change that makes it fail:
##
## * No limit: the candidate root. A limit above the common ancestor (it
##   covers the root too) does not count. Mutation: walking past the common
##   ancestor.
## * A limited, delegated cgroup holds the tree (`L/runquota`); a limited
##   cgroup that is not delegated refuses placement with the reason.
##   Mutation: ignoring the limit (the candidate root comes back).
## * The marker: only an exact directory-name match is left; another name,
##   or a name that only looks like it without the marker, holds. Mutation:
##   matching by the name pattern.
## * A limited cgroup nested inside the marked one holds the tree. Mutation:
##   honouring the marker for any ancestor.
## * Which values are limits: `pids.max` at systemd's default is not, below
##   it is; a `cpu.max` quota is; `memory.high` is.
## * An explicit root follows the same rule, and one at or below L is used
##   as given.
## * Only a `.service` or `.scope` is asked about: a slice, and a plain
##   cgroup whose nearest unit is a slice or the user manager, are never
##   delegated. Mutation: climbing to the nearest unit whatever it is (the
##   slice is accepted).
## * A limit inside RunQuota's own placement (a cap leaf of the default
##   root, of an explicit root, or below a holder's `runquota`) is not a
##   caller's: nothing is placed, nothing asked. Mutations: ignoring
##   RunQuota's own roots (the cap leaf is converted into a holder); checking
##   only the default root (the explicit root's cap leaf is converted).
## * The user manager itself never holds a root, and a slice's refusal says
##   it cannot be delegated rather than advising `-p Delegate=yes`.
## * A "yes" that could not be recorded travels with the placement
##   (`holderNote`), so the launch can say why every launcher asks again.
## * Read-only (`runquota status`): delegation not yet determined, never
##   asked.
## * With placement off nothing is read and nothing asked.
##
## THE ONE STAND-IN, and why: the interface files and extended attributes
## are read through procedures the resolver takes, and this test answers
## them from a table, because the cases need hierarchies (nested limited
## scopes, limits at chosen depths) that a test cannot build on a host. The
## real files and attributes are read by
## `tests/integration/t_cgroup_placement_caller_limits.nim`.
import std/[strutils, tables, unittest]
import runquota_core
import runquota_process

const
  User = "/user.slice/user-1000.slice/user@1000.service"
  Mount = "/sys/fs/cgroup"

var files = initTable[string, string]()
var delegatedDirs: seq[string]
var reads = 0

proc fakeRead(path: string): string {.nimcall, gcsafe, raises: [].} =
  {.cast(gcsafe).}:
    inc reads
    try:
      if path == KernelPidMaxPath: return "4194304"
      if path == KernelThreadsMaxPath: return "1027685"
      files.getOrDefault(path, "")
    except KeyError:
      ""

var delegationCalls = 0

var yesNote = ""

proc fakeDelegated(unitDir: string; mayAsk: bool;
                   answer: var string): DelegationAnswer {.nimcall, gcsafe,
    raises: [].} =
  {.cast(gcsafe).}:
    inc delegationCalls
    if unitDir in delegatedDirs:
      answer = yesNote
      return daYes
    if not mayAsk:
      answer = "not yet determined"
      return daUnknown
    answer = "the table says Delegate=no"
    daNo

proc reset() =
  files.clear()
  delegatedDirs.setLen(0)
  reads = 0
  delegationCalls = 0
  yesNote = ""

proc resolve(own: string; agentScope = ""; explicit = "";
             mayAsk = true): CgroupRoot =
  resolveCgroupRoot(explicit, "0::" & own & "\n", 1000, hostSwitchOn = true,
    isLinux = true, read = fakeRead, agentScope = agentScope,
    delegated = fakeDelegated, mayAsk = mayAsk)

suite "placement under a caller's limits":
  test "no limit: the default root; a limit above the common ancestor does not count":
    reset()
    files[Mount & User & "/memory.max"] = "8589934592"
    let root = resolve(User & "/app.slice/run-1.scope")
    check root.state == crsDefault
    check root.path == Mount & User & "/runquota.slice"
    check root.holder == ""

  test "a limited, delegated scope holds the tree; not delegated refuses":
    reset()
    let scope = Mount & User & "/app.slice/run-2.scope"
    files[scope & "/memory.max"] = "8589934592"
    let refused = resolve(User & "/app.slice/run-2.scope")
    check refused.state == crsUnavailable
    check scope in refused.reason
    check "memory.max=8589934592" in refused.reason
    check "-p Delegate=yes" in refused.reason
    check "the table says Delegate=no" in refused.reason
    delegatedDirs.add(scope)
    let held = resolve(User & "/app.slice/run-2.scope")
    check held.usable
    check held.path == scope & "/runquota"
    check held.holder == scope
    check "memory.max=8589934592" in held.holderLimit
    # The launcher already moved into the caller leaf: the same holder.
    let again = resolve(User & "/app.slice/run-2.scope/caller")
    check again.path == scope & "/runquota"

  test "only the marker's exact name is left":
    reset()
    let scope = Mount & User & "/app.slice/agent-session-7-0-9.scope"
    files[scope & "/memory.max"] = "21474836480"
    let own = User & "/app.slice/agent-session-7-0-9.scope"
    check resolve(own, agentScope = "agent-session-7-0-9.scope").state ==
      crsDefault
    check resolve(own, agentScope = "agent-session-7-0-10.scope").state ==
      crsUnavailable
    check resolve(own).state == crsUnavailable
    check resolve(own, agentScope = "agent-session").state == crsUnavailable

  test "a limited cgroup nested inside the marked scope holds the tree":
    reset()
    let marked = Mount & User & "/app.slice/agent-session-1.scope"
    let inner = marked & "/inner"
    files[marked & "/memory.max"] = "21474836480"
    files[inner & "/memory.max"] = "536870912"
    # A plain cgroup is decided by the unit it lies in.
    delegatedDirs.add(marked)
    let held = resolve(User & "/app.slice/agent-session-1.scope/inner",
      agentScope = "agent-session-1.scope")
    check held.usable
    check held.holder == inner
    check held.path == inner & "/runquota"

  test "which values are limits":
    reset()
    let scope = Mount & User & "/app.slice/run-3.scope"
    let own = User & "/app.slice/run-3.scope"
    # systemd's default: 15% of min(pid_max, threads-max) = 154152.
    files[scope & "/pids.max"] = "154152"
    check resolve(own).state == crsDefault
    files[scope & "/pids.max"] = "64"
    check "pids.max=64" in resolve(own).reason
    reset()
    files[scope & "/cpu.max"] = "200000 100000"
    check "cpu.max=200000 100000" in resolve(own).reason
    reset()
    files[scope & "/cpu.max"] = "max 100000"
    check resolve(own).state == crsDefault
    files[scope & "/memory.high"] = "1073741824"
    check "memory.high=1073741824" in resolve(own).reason
    reset()
    files[scope & "/memory.swap.max"] = "0"
    check "memory.swap.max=0" in resolve(own).reason

  test "an explicit root follows the same rule":
    reset()
    let scope = Mount & User & "/app.slice/run-4.scope"
    let own = User & "/app.slice/run-4.scope"
    let explicit = Mount & User & "/runquota-test.slice"
    check resolve(own, explicit = explicit).path == explicit
    files[scope & "/memory.max"] = "1073741824"
    check resolve(own, explicit = explicit).state == crsUnavailable
    delegatedDirs.add(scope)
    check resolve(own, explicit = explicit).path == scope & "/runquota"
    # A root at or below the limited cgroup leaves nothing.
    check resolve(own, explicit = scope & "/mine").path == scope & "/mine"
    # The marked scope alone between the launcher and the explicit root.
    reset()
    let marked = Mount & User & "/app.slice/agent-session-2.scope"
    files[marked & "/memory.max"] = "1073741824"
    check resolve(User & "/app.slice/agent-session-2.scope",
      agentScope = "agent-session-2.scope", explicit = explicit).path == explicit

  test "a slice, or a plain cgroup of the user manager, is never delegated":
    reset()
    let slice = Mount & User & "/app.slice"
    files[slice & "/memory.max"] = "8589934592"
    delegatedDirs.add(slice)
    let refused = resolve(User & "/app.slice/run-5.scope")
    check refused.state == crsUnavailable
    check (slice & " is a slice") in refused.reason
    check "cannot be delegated" in refused.reason
    check "-p Delegate=yes" notin refused.reason
    check delegationCalls == 0
    reset()
    let plain = Mount & User & "/mine"
    files[plain & "/memory.max"] = "8589934592"
    let underManager = resolve(User & "/mine",
      explicit = Mount & User & "/runquota-test.slice")
    check underManager.state == crsUnavailable
    check "user manager" in underManager.reason
    check delegationCalls == 0
    reset()
    let underSlice = Mount & User & "/app.slice/plain"
    files[underSlice & "/memory.max"] = "8589934592"
    check "nearest unit is the slice" in
      resolve(User & "/app.slice/plain").reason
    check delegationCalls == 0

  test "a limit inside RunQuota's own placement is not a caller's":
    reset()
    # A launcher inside a cap leaf of the default root.
    let leaf = Mount & User & "/runquota.slice/group-g/cap-1-2"
    files[leaf & "/memory.max"] = "67108864"
    let inLeaf = resolve(User & "/runquota.slice/group-g/cap-1-2")
    check inLeaf.state == crsUnavailable
    check "inside another RunQuota-placed tree" in inLeaf.reason
    check inLeaf.holder == ""
    # ... and inside a holder root of a caller's scope.
    reset()
    let scope = Mount & User & "/app.slice/run-6.scope"
    let held = scope & "/runquota/group-g/cap-3-4"
    files[scope & "/memory.max"] = "1073741824"
    files[held & "/memory.max"] = "67108864"
    delegatedDirs.add(scope)
    let inHeld = resolve(User & "/app.slice/run-6.scope/runquota/group-g/cap-3-4")
    check "inside another RunQuota-placed tree" in inHeld.reason
    check delegationCalls == 0

  test "a limit below an explicit root is RunQuota's own":
    reset()
    # The explicit root lies inside a delegated scope, and the launcher in
    # one of its cap leaves: that leaf's limit is a tree's own cap, not a
    # caller's. Nothing is placed and nothing asked (so nothing would be
    # moved or marked).
    let scope = Mount & User & "/app.slice/run-8.scope"
    let explicit = scope & "/mine"
    let leaf = explicit & "/group-x/cap-1-2"
    files[leaf & "/memory.max"] = "67108864"
    delegatedDirs.add(scope)
    let inLeaf = resolve(User & "/app.slice/run-8.scope/mine/group-x/cap-1-2",
      explicit = explicit)
    check inLeaf.state == crsUnavailable
    check "inside another RunQuota-placed tree" in inLeaf.reason
    check inLeaf.holder == ""
    check delegationCalls == 0

  test "the user manager itself never holds a root":
    reset()
    files[Mount & User & "/memory.max"] = "8589934592"
    let refused = resolve(User, explicit = Mount & "/other.slice/root")
    check refused.state == crsUnavailable
    check "the user manager itself" in refused.reason
    check delegationCalls == 0

  test "a recorded-answer failure travels with the placement":
    reset()
    let scope = Mount & User & "/app.slice/run-9.scope"
    files[scope & "/memory.max"] = "1073741824"
    delegatedDirs.add(scope)
    yesNote = "could not record systemd's answer"
    let held = resolve(User & "/app.slice/run-9.scope")
    check held.usable
    check held.holderNote == yesNote
    let target = targetFor(held, "g", sessionPriorityNormal, reclaimed = false)
    check target.holderNote == yesNote

  test "read-only: delegation not yet determined, nothing asked":
    reset()
    let scope = Mount & User & "/app.slice/run-7.scope"
    files[scope & "/memory.max"] = "1073741824"
    let unknown = resolve(User & "/app.slice/run-7.scope", mayAsk = false)
    check unknown.state == crsUnavailable
    check "not known to be delegated" in unknown.reason
    check "not yet determined" in unknown.reason

  test "the unit that decides a cgroup's delegation":
    var why = ""
    check delegationUnit(Mount & User & "/app.slice/x.scope", why) ==
      Mount & User & "/app.slice/x.scope"
    check delegationUnit(Mount & User & "/app.slice/x.scope/a/b", why) ==
      Mount & User & "/app.slice/x.scope"
    check delegationUnit(Mount & User & "/app.slice", why) == ""
    check delegationUnit(Mount & User & "/a", why) == ""
    check delegationUnit(Mount & "/plain", why) == ""

  test "with placement off nothing is read":
    reset()
    discard resolveCgroupRoot("", "0::" & User & "/app.slice/x.scope\n",
      1000, hostSwitchOn = false, isLinux = true, read = fakeRead,
      agentScope = "", delegated = fakeDelegated)
    discard resolveCgroupRoot("off", "0::" & User & "/app.slice/x.scope\n",
      1000, hostSwitchOn = true, isLinux = true, read = fakeRead,
      agentScope = "", delegated = fakeDelegated)
    check reads == 0
    check delegationCalls == 0
