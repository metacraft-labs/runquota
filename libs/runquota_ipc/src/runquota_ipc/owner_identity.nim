## Who a connection's peer is, and who THIS process is, as an owner id.
##
## ``runquota_core/owner_id`` says what the integer is; this module says
## where the principal it is computed from comes from on each platform:
##
## * the PEER's principal, from the credentials ``peerIdentity`` read off
##   the accepted connection -- the uid on a Unix socket, the token user SID
##   on a named pipe. This is the only source the daemon may record an owner
##   from (``docs/database.md``: "never from anything the client declares");
## * THIS process's principal, for the Hello ``userId`` a client sends and
##   for the tests that assert uid scoping: ``getuid()`` on POSIX, the user
##   SID of this process's own token on Windows. Both ends reading a token
##   and hashing the same SID string is what makes the Hello check a real
##   comparison on Windows rather than ``0 == 0``;
## * a human-readable NAME for a principal, for the ``users`` table's
##   diagnostics column: the login name (``getpwuid_r``) on POSIX,
##   ``DOMAIN\user`` (``LookupAccountSidW``) on Windows. A name is never an
##   identity -- two hosts may call two accounts ``alice`` -- so it is only
##   ever displayed, never compared.
##
## No ``ref`` types: ``runquota_ipc`` is a static helper.

import std/[options, strutils]

import runquota_core/owner_id
import ./types

export owner_id

when defined(posix):
  import std/posix

when defined(windows):
  import std/winlean

  type WinHandle = winlean.Handle

  const
    TokenUserClass = 1'i32
      ## ``TOKEN_INFORMATION_CLASS`` ``TokenUser``.
    TokenQueryAccess = 0x0008'i32
      ## ``TOKEN_QUERY``.
    ProcessQueryLimitedInformation = 0x1000'i32
      ## ``PROCESS_QUERY_LIMITED_INFORMATION``: enough to open the token of
      ## a process owned by another user, which ``PROCESS_QUERY_INFORMATION``
      ## is not always.
    ErrorInsufficientBuffer = 122'i32

  proc openProcessToken(
    ProcessHandle: WinHandle, DesiredAccess: int32, TokenHandle: ptr WinHandle
  ): WINBOOL {.stdcall, dynlib: "advapi32.dll", importc: "OpenProcessToken".}

  proc getTokenInformation(
    TokenHandle: WinHandle, TokenInformationClass: int32,
    TokenInformation: pointer, TokenInformationLength: int32,
    ReturnLength: ptr int32
  ): WINBOOL {.stdcall, dynlib: "advapi32.dll", importc: "GetTokenInformation".}

  proc convertSidToStringSidW(
    Sid: pointer, StringSid: ptr ptr uint16
  ): WINBOOL {.stdcall, dynlib: "advapi32.dll", importc: "ConvertSidToStringSidW".}

  proc convertStringSidToSidW(
    StringSid: WideCString, Sid: ptr pointer
  ): WINBOOL {.stdcall, dynlib: "advapi32.dll", importc: "ConvertStringSidToSidW".}

  proc lookupAccountSidW(
    lpSystemName: pointer, Sid: pointer, Name: ptr uint16, cchName: ptr int32,
    ReferencedDomainName: ptr uint16, cchReferencedDomainName: ptr int32,
    peUse: ptr int32
  ): WINBOOL {.stdcall, dynlib: "advapi32.dll", importc: "LookupAccountSidW".}

  proc localFree(hMem: pointer): pointer {.
    stdcall, dynlib: "kernel32.dll", importc: "LocalFree".}

  proc getCurrentProcess(): WinHandle {.
    stdcall, dynlib: "kernel32.dll", importc: "GetCurrentProcess".}

  proc tokenUserSid(token: WinHandle): string =
    ## The string form of the token's user SID, or "" if any step fails.
    var needed: int32 = 0
    discard getTokenInformation(token, TokenUserClass, nil, 0, addr needed)
    if needed <= 0:
      return ""
    var buffer = newString(needed)
    if getTokenInformation(token, TokenUserClass, addr buffer[0], needed,
        addr needed) == 0:
      return ""
    # TOKEN_USER is { SID_AND_ATTRIBUTES User; } and SID_AND_ATTRIBUTES is
    # { PSID Sid; DWORD Attributes; }, so the first pointer-sized field is
    # the SID.
    let sidPointer = cast[ptr pointer](addr buffer[0])[]
    var text: ptr uint16 = nil
    if convertSidToStringSidW(sidPointer, addr text) == 0 or text == nil:
      return ""
    result = $cast[WideCString](text)
    discard localFree(text)

  proc processUserSid*(process: WinHandle): string =
    ## The user SID of ``process``'s primary token, or "".
    var token: WinHandle = 0
    if openProcessToken(process, TokenQueryAccess, addr token) == 0:
      return ""
    result = tokenUserSid(token)
    discard closeHandle(token)

  proc processIdUserSid*(processId: int32): string =
    ## The user SID of the process ``processId``, or "". Used for a named
    ## pipe's client, whose pid ``GetNamedPipeClientProcessId`` reports.
    let process = openProcess(ProcessQueryLimitedInformation, 0'i32,
      processId)
    if process == 0:
      return ""
    result = processUserSid(process)
    discard closeHandle(process)

  proc currentProcessUserSid*(): string =
    ## The user SID of this process's own token, or "".
    processUserSid(getCurrentProcess())

  proc wideText(buffer: openArray[uint16]; length: int32): string =
    if length <= 0 or buffer.len == 0:
      return ""
    var copy = newSeq[uint16](int(length) + 1)
    for i in 0 ..< min(int(length), buffer.len):
      copy[i] = buffer[i]
    $cast[WideCString](addr copy[0])

  proc windowsAccountName(sid: string): Option[string] =
    ## ``DOMAIN\user`` for ``sid``, or none when the account cannot be
    ## resolved (deleted, or on a domain this host cannot reach).
    var sidPointer: pointer = nil
    let wide = newWideCString(sid)
    if convertStringSidToSidW(wide, addr sidPointer) == 0 or
        sidPointer == nil:
      return none(string)
    defer: discard localFree(sidPointer)
    var nameLength = 256'i32
    var domainLength = 256'i32
    var name = newSeq[uint16](nameLength)
    var domain = newSeq[uint16](domainLength)
    var use = 0'i32
    var ok = lookupAccountSidW(nil, sidPointer, addr name[0], addr nameLength,
      addr domain[0], addr domainLength, addr use) != 0
    if not ok and getLastError() == ErrorInsufficientBuffer and
        nameLength > 0 and domainLength >= 0:
      name = newSeq[uint16](nameLength + 1)
      domain = newSeq[uint16](max(1'i32, domainLength) + 1)
      ok = lookupAccountSidW(nil, sidPointer, addr name[0], addr nameLength,
        addr domain[0], addr domainLength, addr use) != 0
    if not ok:
      return none(string)
    let account = wideText(name, nameLength)
    let domainName = wideText(domain, domainLength)
    if account.len == 0:
      return none(string)
    some(if domainName.len > 0: domainName & "\\" & account else: account)

type
  OwnerPrincipalKind* = enum
    ## What an owner id was derived from. The string values are the
    ## ``users.principal_kind`` column's.
    opkUid = "uid"
    opkSid = "sid"

  OwnerPrincipal* = object
    ## An owner, as the platform named it: the id and what it was derived
    ## from. ``principal`` is the uid in decimal, or the SID string.
    ownerId*: int64
    kind*: OwnerPrincipalKind
    principal*: string

  OwnerNameResolver* = proc (principal: OwnerPrincipal): Option[string] {.
    nimcall, gcsafe.}
    ## Turns a principal into a display name. The daemon passes
    ## ``resolveOwnerName``; a test passes its own, which is how a rename is
    ## simulated without renaming a real account.

proc uidPrincipal*(uid: uint64): OwnerPrincipal =
  OwnerPrincipal(ownerId: int64(uid), kind: opkUid, principal: $uid)

proc sidPrincipal*(sid: string): OwnerPrincipal =
  OwnerPrincipal(ownerId: ownerIdFromSid(sid), kind: opkSid,
    principal: sid.toUpperAscii)

proc ownerPrincipalOf*(peer: PeerIdentity): Option[OwnerPrincipal] =
  ## The principal a peer's credentials name, or none when the transport
  ## reported none. THE ONLY SOURCE an owner may be recorded from.
  if peer.kind == peerIdentityUnavailable:
    return none(OwnerPrincipal)
  if peer.sid.len > 0:
    return some(sidPrincipal(peer.sid))
  some(uidPrincipal(peer.userId))

proc ownerIdOf*(peer: PeerIdentity): Option[int64] =
  ## The ``owner_uid`` to record for rows this peer produced. NONE -- which
  ## the store writes as NULL, never 0 -- when the transport could not
  ## report credentials: 0 is root, and a wrong owner is worse than an
  ## absent one.
  let principal = ownerPrincipalOf(peer)
  if principal.isNone: none(int64) else: some(principal.get.ownerId)

proc currentProcessPrincipal*(): Option[OwnerPrincipal] =
  ## This process's own principal, derived exactly as the daemon derives a
  ## peer's: ``getuid()`` on POSIX, the token user SID on Windows.
  when defined(posix):
    some(uidPrincipal(uint64(getuid())))
  elif defined(windows):
    let sid = currentProcessUserSid()
    if sid.len == 0: none(OwnerPrincipal) else: some(sidPrincipal(sid))
  else:
    none(OwnerPrincipal)

proc currentProcessOwnerId*(): Option[int64] =
  ## THIS process's owner id: what the daemon will record for its
  ## connections, and what its Hello declares.
  let principal = currentProcessPrincipal()
  if principal.isNone: none(int64) else: some(principal.get.ownerId)

proc resolveOwnerName*(principal: OwnerPrincipal): Option[string] {.
    nimcall, gcsafe.} =
  ## The platform's display name for ``principal``, or none when it cannot
  ## be resolved -- a deleted account, an unreachable domain, a uid with no
  ## passwd entry. Never raises.
  ##
  ## IT MAY BLOCK: ``getpwuid_r`` can consult NSS/LDAP and
  ## ``LookupAccountSidW`` a domain controller. The daemon therefore calls it
  ## on the connection's own worker BEFORE taking the daemon-wide lock,
  ## never under it.
  case principal.kind
  of opkUid:
    when defined(posix):
      if not isUidOwnerId(principal.ownerId):
        return none(string)
      var entry: Passwd
      var found: ptr Passwd = nil
      var buffer = newString(16_384)
      let status = getpwuid_r(Uid(principal.ownerId), addr entry,
        cstring(buffer), buffer.len, addr found)
      if status != 0 or found == nil or entry.pw_name == nil:
        return none(string)
      let name = $entry.pw_name
      if name.len == 0: none(string) else: some(name)
    else:
      none(string)
  of opkSid:
    when defined(windows):
      {.cast(gcsafe).}:
        windowsAccountName(principal.principal)
    else:
      none(string)
