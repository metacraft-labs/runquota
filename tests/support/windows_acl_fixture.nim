## Windows ACL fixtures for the host-state-directory trust tests, built and
## read with the operating system's OWN tools rather than with the code
## under test.
##
## THE POINT IS INDEPENDENCE. The POSIX arm of these tests builds its
## fixtures with `chmod` and reads them back with `lstat`, neither of which
## is RunQuota code. The Windows equivalents are `icacls` (which writes a
## DACL the way an operator does), `whoami` (which says who this process
## is) and .NET's ACL API through PowerShell (which says who owns a path).
## A fixture built through `runquota_ipc` and then judged by `runquota_ipc`
## would prove only that the library agrees with itself.
##
## Every helper FAILS LOUDLY -- `doAssert` with the tool's own output --
## rather than returning a fixture that silently is not what it claims:
## a directory that was meant to be world-writable and is not would turn
## a refusal test into an acceptance.

when defined(windows):
  import std/[os, osproc, strutils]

  proc systemTool(name: string): string =
    ## A Windows system tool by ABSOLUTE path, never by PATH lookup. A dev
    ## shell can put Git for Windows' `/usr/bin` ahead of `System32`, and
    ## its coreutils `whoami` rejects `/user` as an extra operand -- a
    ## fixture that asked PATH would be judged by whichever tool won.
    let root = getEnv("SystemRoot", r"C:\Windows")
    for candidate in [root / "System32" / name,
        root / "System32" / "WindowsPowerShell" / "v1.0" / name]:
      if fileExists(candidate):
        return candidate
    doAssert false, "no " & name & " under " & root
    ""

  proc runTool(command: string; args: openArray[string]): (int, string) =
    ## Runs a system tool with its arguments passed as given, stderr folded
    ## into the output, and returns (exit code, output).
    ##
    ## `execCmdEx`, NOT `startProcess` + `outputStream.readAll`: on Windows
    ## the latter returned the first byte of `whoami /fo csv` -- a lone `"`
    ## -- and nothing else, which a fixture would read as an empty answer.
    var all = @[systemTool(command)]
    for arg in args:
      all.add(arg)
    let (output, code) = execCmdEx(quoteShellCommand(all),
      options = {poStdErrToStdOut})
    (code, output)

  proc runCmdLine*(commandLine: string): (int, string) =
    ## Runs ``commandLine`` through ``cmd.exe`` EXACTLY as an operator who
    ## pasted it would. ``/s`` strips only the outer quotes this adds, so
    ## the quotes inside the line reach ``cmd`` untouched -- which is what
    ## lets a test run the very string a refusal printed.
    let (output, code) = execCmdEx("\"" & systemTool("cmd.exe") &
      "\" /d /s /c \"" & commandLine & "\"", options = {poStdErrToStdOut})
    (code, output)

  proc icacls*(path: string; args: openArray[string]) =
    ## ``icacls <path> <args...>``, which must succeed.
    var all = @[path]
    for arg in args:
      all.add(arg)
    let (code, output) = runTool("icacls.exe", all)
    doAssert code == 0, "icacls " & all.join(" ") & " failed (" & $code &
      "): " & output

  proc currentUserSid*(): string =
    ## This process's user SID, as ``whoami /user`` reports it.
    let (code, output) = runTool("whoami.exe", ["/user", "/fo", "csv", "/nh"])
    doAssert code == 0, "whoami /user failed: " & output
    # "DOMAIN\name","S-1-5-21-..."
    let fields = output.strip().split(',')
    doAssert fields.len == 2, "unexpected whoami output: " & output
    result = fields[1].strip(chars = {'"', ' ', '\r', '\n'})
    doAssert result.startsWith("S-1-"), "unexpected whoami SID: " & output

  proc powershell(script: string): string =
    ## Windows PowerShell running one script, which must succeed. .NET's own
    ## ``System.IO.Directory`` ACL calls are used rather than the
    ## ``Get-Acl`` / ``Set-Acl`` cmdlets: those live in a module that a
    ## ``PSModulePath`` inherited from PowerShell 7 can make unloadable, and
    ## a fixture that depends on the caller's shell is not a fixture.
    let (code, output) = runTool("powershell.exe",
      ["-NoProfile", "-NonInteractive", "-Command", script])
    doAssert code == 0, "powershell " & script & " failed: " & output
    output.strip()

  proc psQuote(path: string): string =
    "'" & path.replace("'", "''") & "'"

  proc ownerSidOf*(path: string): string =
    ## The owner of ``path`` as a SID, as .NET's ACL API reads it.
    result = powershell("[System.IO.Directory]::GetAccessControl(" &
      psQuote(path) &
      ").GetOwner([System.Security.Principal.SecurityIdentifier]).Value")
    doAssert result.startsWith("S-1-"), "unexpected owner for " & path &
      ": " & result

  proc setNullDacl*(path: string) =
    ## Replaces ``path``'s DACL with a NULL one -- ``D:NO_ACCESS_CONTROL``,
    ## which Windows reads as "Everyone: full control".
    discard powershell(
      "$s = New-Object System.Security.AccessControl.DirectorySecurity; " &
      "$s.SetSecurityDescriptorSddlForm('D:NO_ACCESS_CONTROL'); " &
      "[System.IO.Directory]::SetAccessControl(" & psQuote(path) & ", $s)")

  proc restrictToOwnerAndSystem*(path: string) =
    ## The DACL "this daemon owns and nobody else can write": inheritance
    ## removed, full control for this user, SYSTEM and Administrators, and
    ## nothing for anyone else.
    icacls(path, ["/inheritance:r", "/grant:r",
      "*" & currentUserSid() & ":(OI)(CI)F", "*S-1-5-18:(OI)(CI)F",
      "*S-1-5-32-544:(OI)(CI)F"])

  proc grantUsersCreate*(path: string) =
    ## EXACTLY what ``C:\ProgramData`` hands every directory created under
    ## it: ``BUILTIN\Users:(CI)(WD,AD,WEA,WA)`` -- any local user may add
    ## files and subdirectories. This is the ACE the observed host carried.
    icacls(path, ["/grant", "*S-1-5-32-545:(CI)(WD,AD,WEA,WA)"])
