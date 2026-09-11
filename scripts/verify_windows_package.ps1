<#
.SYNOPSIS
  Read a built RunQuota MSI's own tables and refuse one that does not
  install what the `Distribution` says it installs.

.DESCRIPTION
  THE CLAIM THIS CHECKS. `packaging/runquota_dist.nim` declares one
  `ServiceDef` with `scope: ssSystem`, `startAtBoot: false`,
  `restartOnFailure: true` and an EMPTY `execArgs`. Every one of those is
  a statement about rows in the shipped database, and every one of them
  can be wrong in a way that produces a perfectly valid MSI:

  * an `ssUser` service is DROPPED by `msiServiceRows` -- the SCM has no
    per-user services -- so the wrong scope yields an installer with no
    service at all and no error anywhere;
  * `execArgs` is passed through VERBATIM by every service renderer, so a
    POSIX path in it lands in `BINARY_PATH_NAME` on a host that has no
    such path (reprobuild's M1 N22, found by reading `sc qc` and not by
    any build-time check);
  * a service row pointing at the wrapper rather than the real image
    fails to start with error 193, and the wrapper is what `crExecutable`
    installs under the public name when `wrapExecutables` is on.

  WHAT MAKES THIS A CHECK ON SHIPPED BYTES. The MSI is opened through
  `WindowsInstaller.Installer`, which reads the compound document itself,
  and every assertion below is an SQL query against the installed
  database's tables. Nothing here reads the `.wxs` the producer
  generated: that is the INPUT, and a check over it could only establish
  that the renderer agrees with itself.

  VACUITY REFUSALS. A query that returns no rows is a failure, not a
  silent pass; a run that made no assertions is a failure; and the
  summary line names how many assertions actually ran.

.PARAMETER MsiPath
  The built `.msi`.

.PARAMETER ExpectedVersion
  The `ProductVersion` the MSI must carry -- MSI's `major.minor.build`,
  so the packaging release is deliberately NOT part of it.

.PARAMETER ExpectedUpgradeCode
  The `UpgradeCode` property. It is what makes two releases of this
  product an upgrade rather than two side-by-side installs, so a changed
  one is a silent, serious regression.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$MsiPath,
  [Parameter(Mandatory = $true)][string]$ExpectedVersion,
  [Parameter(Mandatory = $true)][string]$ExpectedUpgradeCode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:failed = 0
$script:asserted = 0

function Assert-That {
  param([Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$What)
  $script:asserted++
  if ($Condition) {
    Write-Output "ok   $What"
  } else {
    $script:failed++
    Write-Output "FAIL $What"
  }
}

$MsiPath = (Resolve-Path -LiteralPath $MsiPath).Path

# THE FILE IS AN OLE2 COMPOUND DOCUMENT, checked before anything opens
# it. `OpenDatabase` on a non-MSI throws, and a thrown exception here
# would be reported as "the script crashed" rather than as "the artifact
# is not an MSI"; those deserve different messages.
# `[IO.File]::ReadAllBytes` rather than `Get-Content -AsByteStream`:
# the latter is PowerShell 6+, and this script has to run under the
# Windows PowerShell 5.1 that is on every Windows host whether or not
# pwsh was installed.
$allBytes = [IO.File]::ReadAllBytes($MsiPath)
if ($allBytes.Length -lt 8) { throw "the artifact is shorter than an OLE2 header: $MsiPath" }
$magic = $allBytes[0..7]
$expectedMagic = [byte[]](0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1)
$magicOk = $true
for ($i = 0; $i -lt 8; $i++) { if ($magic[$i] -ne $expectedMagic[$i]) { $magicOk = $false } }
Assert-That -Condition $magicOk -What "the artifact is an OLE2 compound document (MSI container)"
if (-not $magicOk) {
  Write-Output "FAILED=$script:failed ASSERTED=$script:asserted"
  exit 1
}

$installer = New-Object -ComObject WindowsInstaller.Installer
# 0 = msiOpenDatabaseModeReadOnly.
$db = $installer.GetType().InvokeMember(
  'OpenDatabase', 'InvokeMethod', $null, $installer, @($MsiPath, 0))

function Get-MsiRows {
  <#
    Run one SQL query and return its rows as arrays of strings.

    THROUGH A LIST, NOT A PIPELINE, and TWO PowerShell hazards are why.

    1. A void COM method called through `InvokeMember` returns `$null`,
       and PowerShell WRITES a bare `$null` statement to the output
       stream. The `Execute` and `Close` calls therefore each prepended a
       null row to this function's result until they were `[void]`-cast,
       and the caller's `$row[0]` met it as "cannot index into a null
       array".

    2. `return $rows` UNROLLS the list. A query returning exactly one row
       would hand the caller that row's `string[]` rather than a
       one-element list, and `foreach` would then walk its COLUMNS as if
       they were rows. That is not a hypothetical here: the
       `ServiceInstall` query returns exactly one row and is the most
       important assertion in the file. `, $rows` wraps the list in a
       one-element array so the unrolling hands back the list itself.
  #>
  param([string]$Sql, [int]$Columns)
  $view = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db, @($Sql))
  [void]$view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null)
  $rows = New-Object System.Collections.Generic.List[object]
  while ($true) {
    $record = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
    if ($null -eq $record) { break }
    $values = @()
    for ($c = 1; $c -le $Columns; $c++) {
      $values += [string]$record.GetType().InvokeMember(
        'StringData', 'GetProperty', $null, $record, @($c))
    }
    [void]$rows.Add($values)
  }
  [void]$view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null)
  return , $rows
}

Write-Output "msi       : $MsiPath"
Write-Output ''

# ---- PROPERTIES ------------------------------------------------------
$props = @{}
foreach ($row in (Get-MsiRows -Sql "SELECT Property, Value FROM Property" -Columns 2)) {
  $props[$row[0]] = $row[1]
}
Assert-That -Condition ($props.Count -gt 0) -What "the Property table is not empty"
Assert-That -Condition ($props.ContainsKey('ProductName') -and $props['ProductName'] -eq 'runquota') `
  -What "ProductName is 'runquota' (got '$(if ($props.ContainsKey('ProductName')) { $props['ProductName'] } else { '<absent>' })')"
Assert-That -Condition ($props.ContainsKey('ProductVersion') -and $props['ProductVersion'] -eq $ExpectedVersion) `
  -What "ProductVersion is '$ExpectedVersion' (got '$(if ($props.ContainsKey('ProductVersion')) { $props['ProductVersion'] } else { '<absent>' })')"
Assert-That -Condition ($props.ContainsKey('UpgradeCode') -and $props['UpgradeCode'] -eq $ExpectedUpgradeCode) `
  -What "UpgradeCode is $ExpectedUpgradeCode"

# ---- THE FILES -------------------------------------------------------
$files = @{}
foreach ($row in (Get-MsiRows -Sql "SELECT File, FileName FROM File" -Columns 2)) {
  # MSI's FileName is `short|long` when a short name was generated.
  $long = $row[1]
  if ($long -match '\|') { $long = $long.Split('|')[-1] }
  $files[$long.ToLowerInvariant()] = $row[0]
}
Assert-That -Condition ($files.Count -ge 3) `
  -What "the File table carries at least the three shipped files (found $($files.Count))"
foreach ($shipped in @('runquota.exe', 'runquotad.exe', 'LICENSE')) {
  Assert-That -Condition ($files.ContainsKey($shipped.ToLowerInvariant())) `
    -What "the File table carries $shipped"
}

# ---- THE SERVICE -----------------------------------------------------
#
# `Arguments` is column 5 of ServiceInstall and is what becomes the tail
# of `BINARY_PATH_NAME`. RunQuota's `ServiceDef.execArgs` is empty on
# purpose (the daemon's compiled-in `hostWideStateDir` is already
# per-target), so ANY value here means a path or a flag crossed into the
# service that the recipe did not intend.
$svc = Get-MsiRows -Sql "SELECT ServiceInstall, Name, DisplayName, StartType, Arguments, Component_ FROM ServiceInstall" -Columns 6
Assert-That -Condition ($svc.Count -eq 1) `
  -What "exactly one ServiceInstall row (found $($svc.Count)) -- an ssUser service would have been dropped, leaving zero"
if ($svc.Count -eq 1) {
  $row = $svc[0]
  Assert-That -Condition ($row[1] -eq 'runquotad') -What "the service is named 'runquotad' (got '$($row[1])')"
  Assert-That -Condition ($row[2] -eq 'RunQuota lease authority') -What "DisplayName is 'RunQuota lease authority' (got '$($row[2])')"
  # msidbServiceInstallDemandStart = 3. `startAtBoot: false` is a
  # decision with a reason (the daemon would otherwise begin governing a
  # machine against capacity numbers nobody chose), so an auto-start row
  # here is a regression and not a nicety.
  Assert-That -Condition ($row[3] -eq '3') -What "StartType is demand-start (3), not auto-start (got '$($row[3])')"
  Assert-That -Condition ([string]::IsNullOrEmpty($row[4])) `
    -What "Arguments is EMPTY -- no POSIX path can have crossed into BINARY_PATH_NAME (got '$($row[4])')"

  # THE SERVICE IMAGE IS THE REAL BINARY. A ServiceInstall row's
  # component key path is the executable the SCM will run; pointing it at
  # a `.cmd` wrapper produces a service that fails to start with error
  # 193, which registration alone cannot reveal.
  $comp = Get-MsiRows -Sql "SELECT Component, KeyPath FROM Component WHERE Component = '$($row[5])'" -Columns 2
  Assert-That -Condition ($comp.Count -eq 1) -What "the service's Component row exists"
  if ($comp.Count -eq 1) {
    $keyFile = $comp[0][1]
    $keyName = (Get-MsiRows -Sql "SELECT File, FileName FROM File WHERE File = '$keyFile'" -Columns 2)
    Assert-That -Condition ($keyName.Count -eq 1) -What "the service component's key path names a File row"
    if ($keyName.Count -eq 1) {
      $long = $keyName[0][1]
      if ($long -match '\|') { $long = $long.Split('|')[-1] }
      Assert-That -Condition ($long -ieq 'runquotad.exe') `
        -What "the SCM will run runquotad.exe itself, not a wrapper (got '$long')"
    }
  }
}

# UNINSTALL MUST REVERT THE SERVICE. Without a ServiceControl row the
# service survives `msiexec /x` as a registration pointing at a deleted
# image -- an entry `sc query` still answers for and nothing can start.
$svcControl = Get-MsiRows -Sql "SELECT ServiceControl, Name, Event FROM ServiceControl" -Columns 3
Assert-That -Condition ($svcControl.Count -ge 1) `
  -What "at least one ServiceControl row (found $($svcControl.Count)) -- this is what removes the service on uninstall"

# ---- PATH ------------------------------------------------------------
# `-*` is MSI's "remove on uninstall" prefix; without it the installer
# leaves a dangling directory on the machine PATH forever.
$env_ = Get-MsiRows -Sql "SELECT Environment, Name, Value FROM Environment" -Columns 3
Assert-That -Condition ($env_.Count -ge 1) -What "the Environment table adds the package's bin to PATH"
foreach ($e in $env_) {
  Assert-That -Condition ($e[1] -match '^\W*Path$') -What "the environment entry targets Path (got '$($e[1])')"
}

Write-Output ''
Write-Output "ASSERTED=$script:asserted FAILED=$script:failed"
if ($script:asserted -lt 10) {
  # VACUITY REFUSAL. A run that made almost no assertions cannot have
  # established the claim above, however green it looks.
  Write-Output "FAIL only $script:asserted assertions ran; refusing to pass on an empty sweep"
  exit 1
}
if ($script:failed -gt 0) { exit 1 }
exit 0
