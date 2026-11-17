## What the KERNEL says about a connection's namespaces, and how the daemon
## reconciles it with what the client's `Hello` claims
## (`runquota_protocol/client_namespaces`).
##
## WHY A CLAIM IS NOT ENOUGH. The namespace tokens are written by the client.
## Taken at their word, a client on the host could say "I am in another user
## namespace" to skip the refusal of a declared uid that disagrees with its
## peer credentials, or "I am in another pid namespace" to have the daemon
## watch its connection's peer instead of the child it launched. So the
## daemon looks for itself wherever the kernel lets it, with files every
## process may read (a daemon running as an unprivileged account cannot open
## another user's `/proc/<pid>/ns/*`, and the forwarder of an incus proxy
## device is not even dumpable):
##
## * `/proc/<peer>/status` `NSpid:` lists the peer's pid in every pid
##   namespace from the reader's procfs down to its own. One entry: the peer
##   is in the daemon's pid namespace. More: it is in a descendant one.
## * `/proc/<peer>/uid_map` is shown relative to the READER's user
##   namespace, and to that namespace's parent when the target shares the
##   reader's namespace -- so it reads exactly like `/proc/self/uid_map` when
##   the peer is in the daemon's user namespace, and differently when it is
##   in a child one (a mapping can coincide only for a privileged child that
##   maps the full range onto itself, and root needs no excuse).
##
## HOW THE TWO ARE RECONCILED (`judgeNamespaces`):
##
## * Kernel evidence of a FOREIGN namespace stands whatever the client said:
##   a client that connects directly from a container is read correctly even
##   if it predates the tokens.
## * When the peer IS the client -- the kernel puts it in the daemon's pid
##   namespace and its pid is the one the `Hello` names -- the kernel's view
##   is the client's own, so a claim that contradicts it is a lie and the
##   `Hello` is refused, as one declaring somebody else's uid is.
## * Otherwise the peer is a different process from the client: a
##   forwarder (an incus proxy device's `forkproxy` runs on the host, in the
##   host's namespaces, and connects on the container client's behalf). The
##   kernel cannot see behind it, so the claim stands -- and is harmless by
##   construction: the owner is the peer credential, the declared uid is not
##   recorded (`handleHello`), and the child watched in a foreign pid
##   namespace's place is the peer, which is never more lenient than the
##   `LeaseRunning` child pid 0 any client may already report.
## * Where the files cannot be read (not Linux, `hidepid`, a peer already
##   gone) nothing is known, and the claim is read as it was before this
##   module existed.

import std/strutils

import runquota_ipc
import runquota_protocol

type
  NamespaceEvidence* = enum
    ## What the kernel showed about one of the peer's namespaces.
    neUnknown  ## could not be read: no evidence either way
    neSame     ## the peer shares the daemon's namespace
    neForeign  ## the peer is in a namespace nested below the daemon's

  PeerNamespaces* = object
    ## The kernel's evidence for a connection's peer process.
    pid*: NamespaceEvidence
    user*: NamespaceEvidence

  NamespaceVerdict* = object
    ## The namespaces the daemon acts on, or why the `Hello` is refused.
    difference*: NamespaceDifference
    refusal*: string

proc pidEvidenceOfStatus*(statusText: string): NamespaceEvidence =
  ## The `NSpid:` line of a `/proc/<pid>/status`: one pid is the reader's
  ## pid namespace, more is a nested one. A kernel without the line (before
  ## 4.1) or an unreadable file gives `neUnknown`.
  for line in statusText.splitLines():
    if line.startsWith("NSpid:"):
      let ids = line["NSpid:".len .. ^1].splitWhitespace()
      return
        if ids.len == 0: neUnknown
        elif ids.len == 1: neSame
        else: neForeign
  neUnknown

proc normalisedMap(text: string): string =
  ## A `uid_map` with its column padding removed, one mapping per line.
  var lines: seq[string] = @[]
  for line in text.splitLines():
    let fields = line.splitWhitespace()
    if fields.len > 0:
      lines.add(fields.join(" "))
  lines.join("\n")

proc userEvidenceOfMaps*(peerMap, ownMap: string): NamespaceEvidence =
  ## Compares the peer's `uid_map` with the daemon's own, both as the daemon
  ## reads them. An empty map (unreadable, or a namespace whose map was never
  ## written) is no evidence.
  let peer = normalisedMap(peerMap)
  let own = normalisedMap(ownMap)
  if peer.len == 0 or own.len == 0: neUnknown
  elif peer == own: neSame
  else: neForeign

proc readSmallFile(path: string): string =
  ## A procfs file's text, or "" when it cannot be read.
  try: readFile(path)
  except CatchableError: ""

proc observePeerNamespaces*(peer: PeerIdentity): PeerNamespaces =
  ## The kernel's evidence for `peer`'s pid and user namespaces. Reads two
  ## world-readable procfs files of the peer; called once per connection,
  ## outside the daemon-wide lock (`observeHelloPeer`).
  when defined(linux):
    if peer.kind != peerIdentityProcess or peer.processId == 0'u64:
      return PeerNamespaces()
    let base = "/proc/" & $peer.processId
    PeerNamespaces(
      pid: pidEvidenceOfStatus(readSmallFile(base & "/status")),
      user: userEvidenceOfMaps(readSmallFile(base & "/uid_map"),
                               readSmallFile("/proc/self/uid_map")))
  else:
    discard peer
    PeerNamespaces()

proc judgeNamespaces*(claimed: NamespaceDifference; observed: PeerNamespaces;
                      peerIsClient: bool): NamespaceVerdict =
  ## Reconciles the client's claim with the kernel's evidence (see the
  ## module comment). `peerIsClient` is true when the peer's pid is the pid
  ## the `Hello` reports; it counts only together with kernel evidence that
  ## the peer is in the daemon's pid namespace, where the two pids are
  ## comparable at all.
  let selfReported = peerIsClient and observed.pid == neSame
  if selfReported and claimed.pid:
    result.refusal = "client claims another pid namespace, but its peer " &
      "credentials name the client itself, in the daemon's"
    return
  if selfReported and claimed.user and observed.user == neSame:
    result.refusal = "client claims another user namespace, but its peer " &
      "credentials name the client itself, in the daemon's"
    return
  # Past the refusals, a claim stands only where the kernel could not
  # contradict it: behind a forwarder, or without readable evidence.
  result.difference = NamespaceDifference(
    pid: observed.pid == neForeign or claimed.pid,
    user: observed.user == neForeign or claimed.user)
