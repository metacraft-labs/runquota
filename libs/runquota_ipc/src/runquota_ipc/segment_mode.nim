## A SEGMENT FILE'S MODE, on every platform: read it, set it, and create a file
## with it.
##
## The segment rules are written as POSIX modes -- per-user segments `0600`,
## the host-wide stats table `0640`, never group- or world-writable
## (`reprobuild-specs/RunQuota-Shared-Memory-Transport.md` §"Mechanism") --
## and on POSIX a mode is what the kernel stores. This module exists for the
## platform where it is not.
##
## ------------------------------------------------------------------------
## WINDOWS: THE MODE IS A PROJECTION OF THE DACL
## ------------------------------------------------------------------------
##
## A Windows file carries an owner SID, a group SID and a DACL rather than a
## mode. The rule the segments obey is about three populations -- the owner,
## the group, everybody else -- so it is expressed on Windows as a DACL over
## the same three, and READ back as the mode that DACL grants. The rule and
## its refusal messages are therefore one rule on every platform, and a
## blanket "every segment is 0600" is exactly as visible here as there.
## `RunQuota-Shared-Memory-Structures.md` §"Segment files and their mode on
## Windows" is the normative statement; this is its implementation.
##
## Reading, per ALLOW entry that applies to the file itself:
##
##   * its SID is the file's OWNER -> the user bits;
##   * its SID is the file's GROUP, and the group is not also the owner ->
##     the group bits;
##   * its SID is LocalSystem or BUILTIN\Administrators, and it is neither
##     of the above -> nothing. They are the ROOT ANALOGUE: either can take
##     ownership of any file and rewrite any DACL, so counting them would
##     make every file on the machine read as world-writable while
##     protecting nothing -- exactly as a POSIX mode does not count root;
##   * ANY OTHER SID -> the other bits. Not only Everyone: a file writable by
##     one named stranger is writable by someone other than its owner, and
##     that is the fact the "group- or world-writable" invariant exists for.
##
## A NULL DACL grants everything to everybody and reads as `0777`. Deny
## entries are not subtracted, which OVERSTATES access: for the writability
## invariant that errs toward refusing, which is the safe direction, and a
## file this module writes never carries one.
##
## What counts as each bit. Read is `FILE_READ_DATA`; execute is
## `FILE_EXECUTE`; generic rights are mapped the way the file object maps
## them. Write differs by class, deliberately: for the OWNER it is
## `FILE_WRITE_DATA`/`FILE_APPEND_DATA`, while for anybody else `DELETE`,
## `WRITE_DAC` and `WRITE_OWNER` count as write too -- a stranger who may
## rewrite the DACL may grant themselves the data.
##
## Writing a mode produces a PROTECTED DACL -- no entry inherited from the
## directory, which is how a mode behaves and is the whole point: an
## inherited entry is somebody else's decision about who may write the
## segment. It holds an entry for the owner (the mode's user bits, plus the
## rights POSIX gives an owner implicitly: changing the mode, deleting,
## reading the attributes), one for the group when the mode grants the group
## anything, one for Everyone when it grants others anything, and full
## control for LocalSystem and Administrators, which is the Windows norm and
## changes nothing that projection reads.
##
## A FILE IS CREATED WITH ITS MODE, not given it afterwards. A file created
## under the directory's inherited DACL and narrowed later has a window in
## which another account can open it, and a handle opened in that window
## keeps its access forever -- the Windows form of the umask race POSIX
## avoids by passing the mode to `open(2)`. `segmentSecurity` builds the
## descriptor `CreateFileW` takes for exactly that.

when defined(posix):
  import std/posix

when defined(windows):
  import std/winlean

  type
    Sid = pointer
    Acl = pointer

    AclSizeInformation {.pure.} = object
      aceCount: uint32
      aclBytesInUse: uint32
      aclBytesFree: uint32

    AceHeader {.pure.} = object
      aceType: uint8
      aceFlags: uint8
      aceSize: uint16

    AllowAce {.pure.} = object
      ## `ACCESS_ALLOWED_ACE`: the header, the mask, then the SID in place.
      header: AceHeader
      mask: uint32
      sidStart: uint32

  const
    SeFileObject = 1'i32
    OwnerSecurityInformation = 0x1'u32
    GroupSecurityInformation = 0x2'u32
    DaclSecurityInformation = 0x4'u32
    ProtectedDaclSecurityInformation = 0x8000_0000'u32
    AclSizeInformationClass = 2'i32
    AclRevision = 2'u32
    SecurityDescriptorRevision = 1'u32
    SecurityDescriptorMinLength = 64
      ## `SECURITY_DESCRIPTOR_MIN_LENGTH` is 40 on x64; rounded up so the
      ## buffer is generous on every target.
    SeDaclProtected = 0x1000'u16
    AccessAllowedAceType = 0'u8
    InheritOnlyAce = 0x08'u8
    TokenQuery = 0x0008'u32
    TokenUserClass = 1'i32
    TokenOwnerClass = 4'i32
    TokenPrimaryGroupClass = 5'i32
    WinWorldSid = 1'i32
    WinLocalSystemSid = 22'i32
    WinBuiltinAdministratorsSid = 26'i32
    SecurityMaxSidSize = 68

    FileReadData = 0x0001'u32
    FileWriteData = 0x0002'u32
    FileAppendData = 0x0004'u32
    FileExecute = 0x0020'u32
    FileReadAttributes = 0x0080'u32
    FileWriteAttributes = 0x0100'u32
    DeleteRight = 0x0001_0000'u32
    ReadControl = 0x0002_0000'u32
    WriteDac = 0x0004_0000'u32
    WriteOwner = 0x0008_0000'u32
    SynchronizeRight = 0x0010_0000'u32
    FileGenericRead = 0x0012_0089'u32
    FileGenericWrite = 0x0012_0116'u32
    FileGenericExecute = 0x0012_00A0'u32
    FileAllAccess = 0x001F_01FF'u32
    GenericRead = 0x8000_0000'u32
    GenericWrite = 0x4000_0000'u32
    GenericExecute = 0x2000_0000'u32
    GenericAll = 0x1000_0000'u32

    OwnerImplicitRights = ReadControl or WriteDac or WriteOwner or DeleteRight or
      SynchronizeRight or FileReadAttributes or FileWriteAttributes
      ## What a POSIX owner has whatever the mode says: it may read the
      ## attributes, change the mode, and remove its own file. None of these
      ## projects onto a user bit.

  proc getNamedSecurityInfoW(objectName: WideCString; objectType: int32;
      securityInfo: uint32; owner, group: ptr Sid; dacl, sacl: ptr Acl;
      descriptor: ptr pointer): uint32 {.
    stdcall, dynlib: "advapi32.dll", importc: "GetNamedSecurityInfoW".}
  proc setNamedSecurityInfoW(objectName: WideCString; objectType: int32;
      securityInfo: uint32; owner, group: Sid; dacl, sacl: Acl): uint32 {.
    stdcall, dynlib: "advapi32.dll", importc: "SetNamedSecurityInfoW".}
  proc getAclInformation(acl: Acl; info: pointer; infoLen: uint32;
      infoClass: int32): WINBOOL {.
    stdcall, dynlib: "advapi32.dll", importc: "GetAclInformation".}
  proc getAce(acl: Acl; index: uint32; ace: ptr pointer): WINBOOL {.
    stdcall, dynlib: "advapi32.dll", importc: "GetAce".}
  proc equalSid(a, b: Sid): WINBOOL {.
    stdcall, dynlib: "advapi32.dll", importc: "EqualSid".}
  proc isValidSid(sid: Sid): WINBOOL {.
    stdcall, dynlib: "advapi32.dll", importc: "IsValidSid".}
  proc getLengthSid(sid: Sid): uint32 {.
    stdcall, dynlib: "advapi32.dll", importc: "GetLengthSid".}
  proc createWellKnownSid(kind: int32; domain: Sid; sid: pointer;
      size: ptr uint32): WINBOOL {.
    stdcall, dynlib: "advapi32.dll", importc: "CreateWellKnownSid".}
  proc initializeAcl(acl: pointer; length: uint32; revision: uint32): WINBOOL {.
    stdcall, dynlib: "advapi32.dll", importc: "InitializeAcl".}
  proc addAccessAllowedAce(acl: pointer; revision: uint32; mask: uint32;
      sid: Sid): WINBOOL {.
    stdcall, dynlib: "advapi32.dll", importc: "AddAccessAllowedAce".}
  proc initializeSecurityDescriptor(sd: pointer; revision: uint32): WINBOOL {.
    stdcall, dynlib: "advapi32.dll", importc: "InitializeSecurityDescriptor".}
  proc setSecurityDescriptorDacl(sd: pointer; present: WINBOOL; acl: pointer;
      defaulted: WINBOOL): WINBOOL {.
    stdcall, dynlib: "advapi32.dll", importc: "SetSecurityDescriptorDacl".}
  proc setSecurityDescriptorControl(sd: pointer; mask, bits: uint16): WINBOOL {.
    stdcall, dynlib: "advapi32.dll", importc: "SetSecurityDescriptorControl".}
  proc convertSidToStringSidW(sid: Sid; text: ptr WideCString): WINBOOL {.
    stdcall, dynlib: "advapi32.dll", importc: "ConvertSidToStringSidW".}
  proc openProcessToken(process: Handle; access: uint32;
      token: var Handle): WINBOOL {.
    stdcall, dynlib: "advapi32.dll", importc: "OpenProcessToken".}
  proc getTokenInformation(token: Handle; infoClass: int32; info: pointer;
      infoLen: uint32; returned: var uint32): WINBOOL {.
    stdcall, dynlib: "advapi32.dll", importc: "GetTokenInformation".}
  proc localFree(mem: pointer): pointer {.
    stdcall, dynlib: "kernel32.dll", importc: "LocalFree".}

  type SidBytes* = seq[byte]
    ## A SID copied out of whatever buffer it arrived in, so it outlives it.

  proc sidAt(bytes: SidBytes): Sid {.inline.} =
    if bytes.len == 0: nil else: cast[Sid](unsafeAddr bytes[0])

  proc copySid(sid: Sid): SidBytes =
    if sid == nil or isValidSid(sid) == 0: return @[]
    let length = int(getLengthSid(sid))
    result = newSeq[byte](length)
    copyMem(addr result[0], sid, length)

  proc sameSid(a: Sid; b: SidBytes): bool =
    a != nil and b.len > 0 and equalSid(a, sidAt(b)) != 0

  proc wellKnownSid(kind: int32): SidBytes =
    var buffer: array[SecurityMaxSidSize, byte]
    var size = uint32(SecurityMaxSidSize)
    if createWellKnownSid(kind, nil, addr buffer[0], addr size) == 0:
      return @[]
    copySid(addr buffer[0])

  proc sidText*(sid: SidBytes): string =
    ## `S-1-5-...`, or "" when the SID is unusable.
    if sid.len == 0: return ""
    var text: WideCString = nil
    if convertSidToStringSidW(sidAt(sid), addr text) == 0 or text == nil:
      return ""
    result = $text
    discard localFree(cast[pointer](text))

  proc tokenSid(infoClass: int32): SidBytes =
    ## The first SID of a token information record. TOKEN_USER, TOKEN_OWNER
    ## and TOKEN_PRIMARY_GROUP all begin with a pointer to it.
    var token: Handle
    if openProcessToken(getCurrentProcess(), TokenQuery, token) == 0:
      return @[]
    defer: discard closeHandle(token)
    var needed = 0'u32
    discard getTokenInformation(token, infoClass, nil, 0, needed)
    if needed == 0: return @[]
    var buffer = newSeq[byte](int(needed))
    if getTokenInformation(token, infoClass, addr buffer[0], needed,
        needed) == 0:
      return @[]
    copySid(cast[ptr Sid](addr buffer[0])[])

  proc processOwnerSids*(): seq[SidBytes] =
    ## The SIDs that mean "this process's own" for an ownership check: the
    ## token's default OWNER, which is what every object this process creates
    ## is owned by, and its USER. They differ on an elevated administrator
    ## token, whose objects are owned by Administrators; a file owned by
    ## either is the caller's own in the sense `getuid()` means on POSIX.
    result = @[]
    for infoClass in [TokenOwnerClass, TokenUserClass]:
      let sid = tokenSid(infoClass)
      if sid.len > 0 and sid notin result:
        result.add(sid)

  type FileSecurity* = object
    ## What a file's security descriptor says, copied out of it.
    readable*: bool
    owner*: SidBytes
    group*: SidBytes
    mode*: int

  proc classBits(mask: uint32; ownerClass: bool): int =
    ## The rwx bits one ALLOW entry's mask grants, as a 0..7 triple.
    let all = (mask and GenericAll) != 0
    if all or (mask and (FileReadData or GenericRead)) != 0:
      result = result or 4
    var writeRights = FileWriteData or FileAppendData or GenericWrite
    if not ownerClass:
      writeRights = writeRights or DeleteRight or WriteDac or WriteOwner
    if all or (mask and writeRights) != 0:
      result = result or 2
    if all or (mask and (FileExecute or GenericExecute)) != 0:
      result = result or 1

  proc readFileSecurity*(path: string): FileSecurity =
    ## The owner, the group and the projected mode of ``path``.
    result = FileSecurity(readable: false, mode: -1)
    var owner, group: Sid
    var dacl: Acl
    var descriptor: pointer
    let wide = newWideCString(path)
    if getNamedSecurityInfoW(wide, SeFileObject,
        OwnerSecurityInformation or GroupSecurityInformation or
        DaclSecurityInformation, addr owner, addr group, addr dacl, nil,
        addr descriptor) != 0'u32:
      return
    defer: discard localFree(descriptor)
    result.readable = true
    result.owner = copySid(owner)
    result.group = copySid(group)
    if dacl == nil:
      result.mode = 0o777
      return
    let groupIsOwner = result.group.len > 0 and sameSid(owner, result.group)
    let system = wellKnownSid(WinLocalSystemSid)
    let admins = wellKnownSid(WinBuiltinAdministratorsSid)
    var info: AclSizeInformation
    if getAclInformation(dacl, addr info, uint32(sizeof(info)),
        AclSizeInformationClass) == 0:
      result.mode = -1
      return
    var userBits, groupBits, otherBits = 0
    for index in 0'u32 ..< info.aceCount:
      var raw: pointer
      if getAce(dacl, index, addr raw) == 0 or raw == nil: continue
      let ace = cast[ptr AllowAce](raw)
      if ace.header.aceType != AccessAllowedAceType: continue
      if (ace.header.aceFlags and InheritOnlyAce) != 0: continue
      let sid = cast[Sid](addr ace.sidStart)
      if sameSid(sid, result.owner):
        userBits = userBits or classBits(ace.mask, ownerClass = true)
      elif not groupIsOwner and sameSid(sid, result.group):
        groupBits = groupBits or classBits(ace.mask, ownerClass = false)
      elif sameSid(sid, system) or sameSid(sid, admins):
        discard
      else:
        otherBits = otherBits or classBits(ace.mask, ownerClass = false)
    result.mode = (userBits shl 6) or (groupBits shl 3) or otherBits

  proc rightsFor(bits: int): uint32 =
    if (bits and 4) != 0: result = result or FileGenericRead
    if (bits and 2) != 0: result = result or FileGenericWrite
    if (bits and 1) != 0: result = result or FileGenericExecute

  type SegmentSecurity* = object
    ## A security descriptor expressing one mode, with the storage it points
    ## into. Build it with `initSegmentSecurity`, keep it alive and unmoved
    ## while `CreateFileW` runs, and pass `attributes`.
    ok*: bool
    descriptor: seq[byte]
    acl: seq[byte]
    owner: SidBytes
    group: SidBytes
    everyone: SidBytes
    system: SidBytes
    admins: SidBytes
    attributes*: SECURITY_ATTRIBUTES

  proc buildAcl(sec: var SegmentSecurity; mode: int): bool =
    ## The protected DACL for ``mode`` over ``sec.owner`` / ``sec.group``.
    ## False when the mode cannot be expressed: group bits on a file whose
    ## group IS its owner, where there is no separate group to grant them to.
    let groupBits = (mode shr 3) and 7
    let otherBits = mode and 7
    let groupIsOwner = sec.group.len == 0 or sec.owner == sec.group
    if groupBits != 0 and groupIsOwner:
      return false
    var entries: seq[(uint32, SidBytes)] = @[]
    entries.add((rightsFor((mode shr 6) and 7) or OwnerImplicitRights,
      sec.owner))
    if groupBits != 0:
      entries.add((rightsFor(groupBits), sec.group))
    if otherBits != 0:
      entries.add((rightsFor(otherBits), sec.everyone))
    for privileged in [sec.system, sec.admins]:
      if privileged.len == 0: continue
      if privileged == sec.owner or privileged == sec.group: continue
      entries.add((FileAllAccess, privileged))
    var size = 8 # sizeof(ACL)
    for (_, sid) in entries:
      if sid.len == 0: return false
      size += 8 + sid.len # header + mask, then the SID replaces sidStart
    size = (size + 3) and not 3
    sec.acl = newSeq[byte](size)
    if initializeAcl(addr sec.acl[0], uint32(size), AclRevision) == 0:
      return false
    for (mask, sid) in entries:
      if addAccessAllowedAce(addr sec.acl[0], AclRevision, mask,
          sidAt(sid)) == 0:
        return false
    true

  proc initSegmentSecurity*(sec: var SegmentSecurity; mode: int) =
    ## A descriptor for a NEW file of ``mode``, owned (as every object this
    ## process creates is) by the token's default owner and grouped by its
    ## primary group. The descriptor names no owner or group itself -- the
    ## kernel assigns those -- only the DACL, and marks it protected so no
    ## entry is inherited from the directory.
    sec.ok = false
    sec.owner = tokenSid(TokenOwnerClass)
    sec.group = tokenSid(TokenPrimaryGroupClass)
    sec.everyone = wellKnownSid(WinWorldSid)
    sec.system = wellKnownSid(WinLocalSystemSid)
    sec.admins = wellKnownSid(WinBuiltinAdministratorsSid)
    if sec.owner.len == 0: return
    if not sec.buildAcl(mode): return
    sec.descriptor = newSeq[byte](SecurityDescriptorMinLength)
    let sd = addr sec.descriptor[0]
    if initializeSecurityDescriptor(sd, SecurityDescriptorRevision) == 0:
      return
    if setSecurityDescriptorDacl(sd, WINBOOL(1), addr sec.acl[0],
        WINBOOL(0)) == 0:
      return
    if setSecurityDescriptorControl(sd, SeDaclProtected,
        SeDaclProtected) == 0:
      return
    sec.attributes = SECURITY_ATTRIBUTES(
      nLength: int32(sizeof(SECURITY_ATTRIBUTES)),
      lpSecurityDescriptor: sd,
      bInheritHandle: WINBOOL(0))
    sec.ok = true

  proc applySegmentMode(path: string; mode: int): bool =
    ## Rewrite ``path``'s DACL to express ``mode`` over the owner and group
    ## it already has.
    let current = readFileSecurity(path)
    if not current.readable or current.owner.len == 0: return false
    var sec = SegmentSecurity(
      owner: current.owner, group: current.group,
      everyone: wellKnownSid(WinWorldSid),
      system: wellKnownSid(WinLocalSystemSid),
      admins: wellKnownSid(WinBuiltinAdministratorsSid))
    if not sec.buildAcl(mode): return false
    setNamedSecurityInfoW(newWideCString(path), SeFileObject,
      DaclSecurityInformation or ProtectedDaclSecurityInformation,
      nil, nil, addr sec.acl[0], nil) == 0'u32

proc segmentFileMode*(path: string): int =
  ## The mode of the segment file at ``path`` -- the kernel's on POSIX, the
  ## DACL's projection on Windows -- or -1 when it cannot be read.
  when defined(posix):
    var info: Stat
    if lstat(path.cstring, info) != 0: return -1
    int(info.st_mode) and 0o7777
  elif defined(windows):
    readFileSecurity(path).mode
  else:
    -1

proc setSegmentFileMode*(path: string; mode: int): bool =
  ## Give the existing file at ``path`` exactly ``mode``. False on failure,
  ## including a mode Windows cannot express for this file (group bits when
  ## the file's group is its owner).
  when defined(posix):
    chmod(path.cstring, Mode(mode)) == 0
  elif defined(windows):
    applySegmentMode(path, mode)
  else:
    false

proc segmentFileModeSupported*(): bool =
  ## Whether segment modes are real on this platform.
  defined(posix) or defined(windows)
