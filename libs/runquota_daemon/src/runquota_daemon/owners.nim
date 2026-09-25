## The daemon's record of WHO its peers are: the owner ledger.
##
## Every connection's peer credentials name a principal -- a uid, or on
## Windows a token user SID -- and its owner id (``runquota_core/owner_id``)
## is what ``executions.owner_uid`` records. The store keeps one ``users``
## row per owner (schema version 6); this module decides, per Hello, whether
## that row must be written, refreshed, or refused:
##
## * **First sighting** of a principal: its row is written, name and all.
## * **A rename**: the principal is known and the name it resolves to now
##   differs from the one last written. The row's name is refreshed and
##   stamped; ``owner_uid`` never changes.
## * **An unresolvable name** (a deleted account, an unreachable domain):
##   nothing is written, so the last known name is kept.
## * **A collision**: the owner id is already held by a DIFFERENT principal.
##   The Hello is refused, because serving it would put two accounts in one
##   scope. The ledger is seeded from the store at startup, so a collision
##   with an owner an earlier daemon recorded is refused the same way.
##
## THE NAME IS RESOLVED BEFORE THE DAEMON LOCK, by ``observePeerOwner``,
## because resolution can block (NSS/LDAP, a domain controller) and the lock
## is the one every lease decision waits behind. The resolver is a parameter
## so a test can change its answer -- which is how a rename is exercised
## without renaming a real account.
##
## Nothing here reads anything the client declared: the principal comes from
## ``PeerIdentity``, which ``runquota_ipc`` fills from the kernel (a Unix
## socket) or from the peer process's token (a named pipe).

import std/[options, tables]

import runquota_ipc
import runquota_observation_store

type
  KnownOwner* = object
    principal*: OwnerPrincipal
    name*: Option[string]
      ## The name last written for this owner.
    recorded*: bool
      ## Its ``users`` row is known to be committed or queued.

  OwnerLedger* = object
    known*: Table[int64, KnownOwner]
    collisionsRefused*: uint64
      ## Hellos refused because their owner id already belonged to a
      ## different principal. A 62-bit hash makes this vanishingly rare; the
      ## count is what makes "it never happened" checkable.
    records*: uint64
      ## ``users`` upserts handed out: first sightings plus renames.

  OwnerDecision* = object
    refusal*: string
      ## Non-empty: refuse the Hello with this text.
    statement*: string
      ## Non-empty: queue this ``users`` upsert, then ``confirm`` it.

proc toStoreKind*(kind: OwnerPrincipalKind): PrincipalKind =
  case kind
  of opkUid: pkUid
  of opkSid: pkSid

proc toIpcKind*(kind: PrincipalKind): OwnerPrincipalKind =
  case kind
  of pkUid: opkUid
  of pkSid: opkSid

proc initOwnerLedger*(): OwnerLedger =
  OwnerLedger(known: initTable[int64, KnownOwner](), collisionsRefused: 0,
    records: 0)

proc seed*(ledger: var OwnerLedger; rows: openArray[UserRow]) =
  ## Loads what the store already knows, once, at startup.
  for row in rows:
    ledger.known[row.ownerUid] = KnownOwner(
      principal: OwnerPrincipal(ownerId: row.ownerUid,
        kind: toIpcKind(row.principalKind), principal: row.principal),
      name: row.name,
      recorded: true)

proc observePeerOwner*(peer: PeerIdentity;
                       resolve: OwnerNameResolver = resolveOwnerName):
    tuple[principal: Option[OwnerPrincipal], name: Option[string]] =
  ## The principal a peer's credentials name, and its display name as
  ## ``resolve`` answers it now. Call it WITHOUT the daemon lock.
  result.principal = ownerPrincipalOf(peer)
  result.name = none(string)
  if result.principal.isSome:
    result.name = resolve(result.principal.get)

proc decide*(ledger: var OwnerLedger; principal: OwnerPrincipal;
             name: Option[string]; atUnixMillis: int64;
             captureEnabled: bool): OwnerDecision =
  ## What a Hello from ``principal`` requires. See the module header.
  result = OwnerDecision(refusal: "", statement: "")
  let present = ledger.known.hasKey(principal.ownerId)
  let known =
    if present: ledger.known[principal.ownerId]
    else: KnownOwner(principal: principal, name: none(string),
      recorded: false)
  if present and (known.principal.kind != principal.kind or
      known.principal.principal != principal.principal):
    inc ledger.collisionsRefused
    result.refusal = "owner id " & $principal.ownerId &
      " is already held by " & $known.principal.kind & " " &
      known.principal.principal & "; refusing " & $principal.kind & " " &
      principal.principal & " rather than let two accounts share one scope"
    return
  if not present:
    # Remembered even while capture is off, so a collision is refused on
    # the same terms whether or not anything is being recorded.
    ledger.known[principal.ownerId] = known
  if not captureEnabled:
    return
  let renamed = name.isSome and known.name != name
  if known.recorded and not renamed:
    return
  result.statement = userUpsertStatement(principal.ownerId,
    toStoreKind(principal.kind), principal.principal, name, atUnixMillis)

proc confirm*(ledger: var OwnerLedger; principal: OwnerPrincipal;
              name: Option[string]) =
  ## The statement ``decide`` handed out has been queued. A name that did
  ## not resolve does not replace a known one -- the same rule the upsert
  ## itself applies.
  var entry = ledger.known.getOrDefault(principal.ownerId,
    KnownOwner(principal: principal, name: none(string), recorded: false))
  entry.principal = principal
  entry.recorded = true
  if name.isSome:
    entry.name = name
  ledger.known[principal.ownerId] = entry
  inc ledger.records
