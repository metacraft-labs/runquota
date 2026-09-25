## Reading a Windows directory's owner and DACL, and the account a process
## runs as -- the FACTS the Windows form of "who can write this directory"
## is judged from.
##
## FACTS HERE, POLICY ELSEWHERE. This module answers "who owns this
## directory, and which ACEs does its DACL carry", verbatim, and never
## "is it trustworthy". The rule that turns these facts into a verdict is
## `runquota_ipc.inspectDirectoryAcl`, beside the POSIX `inspectPath` it
## is the Windows counterpart of. Keeping the reader free of judgement is
## what lets a test verify its OWN precondition from the same facts --
## "this fixture is owned by another account and writable by nobody
## else" -- without asking the code under test whether it agrees.
##
## HERE, IN `runquota_host_windows`, because that is where
## `RunQuota-Repository-Layout.md`'s module map puts Windows security
## (`security.nim`), and because `runquota_core` is to stay free of native
## OS handles. Two libraries import this one module -- not the backend's
## umbrella -- and only on Windows: `runquota_ipc` (the trust check) and
## `runquota_observation_store` (the provisioning command a refusal prints,
## which names the daemon's own account). It imports nothing but `std`.
##
## A static-helper library, so: no `ref` types, and nothing here holds a
## pointer or a handle past the call that produced it. Every string is
## copied out of the buffer Windows returned before that buffer is freed.

when defined(windows):
  import std/winlean

  type
    AceFacts* = object
      ## One ACE, as the DACL holds it. Nothing is interpreted: a caller
      ## that wants to know what ``mask`` permits compares it against the
      ## Win32 access-right bits itself.
      aceType*: int
        ## ``ACE_HEADER.AceType``: 0 allow, 1 deny, 5/6 the object forms,
        ## 9/10 the callback (conditional) forms, 11/12 callback-object.
      flags*: int
        ## ``ACE_HEADER.AceFlags``: OI 0x01, CI 0x02, NP 0x04, IO 0x08,
        ## INHERITED 0x10.
      mask*: uint32
      sid*: string
        ## The trustee as a string SID. Empty exactly when ``sidKnown`` is
        ## false.
      sidKnown*: bool
        ## False for an ACE type whose layout this reader does not know
        ## (the obsolete compound ACE, or a type Windows adds later). A
        ## caller must treat such an ACE as one it cannot vouch for, never
        ## as one that grants nothing.

    DirectorySecurity* = object
      ## What `readDirectorySecurity` found. ``errorCode == 0`` means the
      ## object was opened and its security read; otherwise nothing else
      ## in here is meaningful.
      errorCode*: int
        ## 0, or the Win32 error that stopped the read. ``2`` (file not
        ## found) and ``3`` (path not found) mean nothing is there.
      attributes*: uint32
        ## ``dwFileAttributes`` of the object ITSELF, never of what a
        ## reparse point leads to: it is opened with
        ## ``FILE_FLAG_OPEN_REPARSE_POINT``, the Windows `lstat`.
      ownerSid*: string
      daclPresent*: bool
        ## False for a NULL DACL, which Windows reads as "Everyone: full
        ## control" -- the opposite of an empty one.
      aces*: seq[AceFacts]

  const
    NoSuchFileError* = 2
    NoSuchPathError* = 3

    ReadControl = 0x00020000'i32
    FileObjectType = 1'i32              # SE_FILE_OBJECT
    OwnerSecurityInformation = 0x1'i32
    DaclSecurityInformation = 0x4'i32
    TokenUserClass = 1'i32
    TokenQuery = 0x0008'i32

  proc getSecurityInfo(handle: Handle; objectType: int32;
                       securityInfo: int32; owner: ptr pointer;
                       group: ptr pointer; dacl: ptr pointer;
                       sacl: ptr pointer; descriptor: ptr pointer): int32 {.
    stdcall, dynlib: "advapi32.dll", importc: "GetSecurityInfo".}
  proc getAce(acl: pointer; index: int32; ace: ptr pointer): WINBOOL {.
    stdcall, dynlib: "advapi32.dll", importc: "GetAce".}
  proc convertSidToStringSidW(sid: pointer; text: ptr pointer): WINBOOL {.
    stdcall, dynlib: "advapi32.dll", importc: "ConvertSidToStringSidW".}
  proc convertStringSidToSidW(text: WideCString; sid: ptr pointer): WINBOOL {.
    stdcall, dynlib: "advapi32.dll", importc: "ConvertStringSidToSidW".}
  proc lookupAccountSidW(systemName: WideCString; sid: pointer;
                         name: ptr Utf16Char; nameLen: ptr int32;
                         domain: ptr Utf16Char; domainLen: ptr int32;
                         use: ptr int32): WINBOOL {.
    stdcall, dynlib: "advapi32.dll", importc: "LookupAccountSidW".}
  proc openProcessTokenW(process: Handle; access: int32;
                         token: ptr Handle): WINBOOL {.
    stdcall, dynlib: "advapi32.dll", importc: "OpenProcessToken".}
  proc getTokenInformationW(token: Handle; infoClass: int32; info: pointer;
                            infoLen: int32; returned: ptr int32): WINBOOL {.
    stdcall, dynlib: "advapi32.dll", importc: "GetTokenInformation".}
  proc localFreeW(memory: pointer): pointer {.
    stdcall, dynlib: "kernel32.dll", importc: "LocalFree".}

  proc sidText(sid: pointer): string =
    ## A SID as ``S-1-...``, or "" when Windows would not render it.
    if sid == nil:
      return ""
    var text: pointer = nil
    if convertSidToStringSidW(sid, addr text) == 0 or text == nil:
      return ""
    result = $cast[WideCString](text)
    discard localFreeW(text)

  proc processUserSid*(): string =
    ## The string SID of the account this process runs as: ``TokenUser``
    ## of its own primary token. For a service registered with
    ## ``Account="LocalSystem"`` -- which is what the shipped MSI
    ## registers -- that is ``S-1-5-18``. "" only when the token could
    ## not be read, which a caller must treat as "unknown", never as
    ## "matches anything".
    var token: Handle = 0
    if openProcessTokenW(getCurrentProcess(), TokenQuery, addr token) == 0:
      return ""
    defer: discard closeHandle(token)
    var needed: int32 = 0
    discard getTokenInformationW(token, TokenUserClass, nil, 0, addr needed)
    if needed <= 0:
      return ""
    var buffer = newSeq[byte](needed)
    if getTokenInformationW(token, TokenUserClass, addr buffer[0], needed,
        addr needed) == 0:
      return ""
    # TOKEN_USER is { SID_AND_ATTRIBUTES User; } and SID_AND_ATTRIBUTES is
    # { PSID Sid; DWORD Attributes; }: the first pointer-sized field points
    # at the SID, inside the same buffer.
    sidText(cast[ptr pointer](addr buffer[0])[])

  proc accountNameOfSid*(sid: string): string =
    ## ``DOMAIN\name`` for a string SID, or "" when it does not resolve.
    ## For MESSAGES ONLY: every decision is taken on the SID, because a
    ## name is what an operator reads and a SID is what the kernel checks.
    if sid.len == 0:
      return ""
    var binary: pointer = nil
    if convertStringSidToSidW(newWideCString(sid), addr binary) == 0 or
        binary == nil:
      return ""
    defer: discard localFreeW(binary)
    var nameLen: int32 = 256
    var domainLen: int32 = 256
    var name = newSeq[Utf16Char](nameLen)
    var domain = newSeq[Utf16Char](domainLen)
    var use: int32 = 0
    if lookupAccountSidW(nil, binary, addr name[0], addr nameLen,
        addr domain[0], addr domainLen, addr use) == 0:
      return ""
    let account = $cast[WideCString](addr name[0])
    let authority = $cast[WideCString](addr domain[0])
    if authority.len > 0: authority & "\\" & account else: account

  proc readAce(ace: pointer): AceFacts =
    ## ACE_HEADER is { BYTE AceType; BYTE AceFlags; WORD AceSize; }, and
    ## every allow/deny/audit form follows it with a DWORD mask. Where the
    ## SID starts depends on the type.
    let bytes = cast[ptr UncheckedArray[byte]](ace)
    result.aceType = int(bytes[0])
    result.flags = int(bytes[1])
    result.mask = cast[ptr uint32](addr bytes[4])[]
    case result.aceType
    of 0, 1, 2, 3, 9, 10, 13, 17, 18, 19:
      # ACCESS_ALLOWED / DENIED / SYSTEM_AUDIT / ALARM, their callback
      # forms, and the SACL-only label / resource / scoped-policy forms:
      # the SID starts right after the mask.
      result.sid = sidText(addr bytes[8])
    of 5, 6, 7, 8, 11, 12, 15, 16:
      # The OBJECT forms: a DWORD of flags after the mask, then up to two
      # GUIDs it announces (ACE_OBJECT_TYPE_PRESENT 0x1,
      # ACE_INHERITED_OBJECT_TYPE_PRESENT 0x2), then the SID.
      let objectFlags = cast[ptr uint32](addr bytes[8])[]
      var offset = 12
      if (objectFlags and 0x1'u32) != 0: offset += 16
      if (objectFlags and 0x2'u32) != 0: offset += 16
      result.sid = sidText(addr bytes[offset])
    else:
      result.sid = ""
    result.sidKnown = result.sid.len > 0

  proc readDirectorySecurity*(path: string): DirectorySecurity =
    ## The owner and DACL of ``path`` itself.
    ##
    ## OPENED, NOT NAMED. ``GetNamedSecurityInfoW`` on a path follows a
    ## reparse point, so a junction planted at the state directory would
    ## be judged by the ACL of whatever it points at while the daemon
    ## writes through it -- the Windows form of the ``stat``-not-``lstat``
    ## mistake the POSIX check avoids. ``FILE_FLAG_OPEN_REPARSE_POINT``
    ## opens the link itself, so its attributes say it is one; and the
    ## security is read from THAT handle, so the answer and the attributes
    ## describe the same object. ``FILE_FLAG_BACKUP_SEMANTICS`` is what
    ## lets ``CreateFileW`` open a directory at all, and the only right
    ## asked for is ``READ_CONTROL``.
    result = DirectorySecurity(errorCode: 0)
    let handle = createFileW(newWideCString(path), DWORD(ReadControl),
      DWORD(FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE), nil,
      DWORD(OPEN_EXISTING),
      DWORD(FILE_FLAG_BACKUP_SEMANTICS or FILE_FLAG_OPEN_REPARSE_POINT), 0)
    if handle == INVALID_HANDLE_VALUE:
      result.errorCode = int(getLastError())
      return
    defer: discard closeHandle(handle)
    var info: BY_HANDLE_FILE_INFORMATION
    if getFileInformationByHandle(handle, addr info) == 0:
      result.errorCode = int(getLastError())
      return
    result.attributes = uint32(info.dwFileAttributes)
    var owner: pointer = nil
    var dacl: pointer = nil
    var descriptor: pointer = nil
    let status = getSecurityInfo(handle, FileObjectType,
      OwnerSecurityInformation or DaclSecurityInformation, addr owner, nil,
      addr dacl, nil, addr descriptor)
    if status != 0:
      result.errorCode = int(status)
      return
    defer: discard localFreeW(descriptor)
    result.ownerSid = sidText(owner)
    result.daclPresent = dacl != nil
    if dacl != nil:
      # ACL is { BYTE AclRevision; BYTE Sbz1; WORD AclSize; WORD AceCount;
      # WORD Sbz2; }.
      let aceCount = int(cast[ptr uint16](
        cast[uint](dacl) + 4'u)[])
      for index in 0 ..< aceCount:
        var ace: pointer = nil
        if getAce(dacl, int32(index), addr ace) == 0 or ace == nil:
          # An ACE Windows itself cannot hand back is not one to skip: it
          # is recorded as unreadable, which the policy refuses.
          result.aces.add(AceFacts(aceType: -1, flags: 0, mask: 0,
            sid: "", sidKnown: false))
          continue
        result.aces.add(readAce(ace))
