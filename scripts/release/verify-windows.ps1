# Real Installer ICEs, MSI tables, embedded cabinets and executable smoke tests.
# No mocks. ZIP executables have already run on their native target runners.
param(
  [Parameter(Mandatory = $true)][string]$Dist,
  [Parameter(Mandatory = $true)][string]$Version
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw 'MSI validation requires a runner account with Windows Installer access'
}
$installer = Get-Service -Name msiserver
if ($installer.Status -ne 'Running') {
  Start-Service -Name msiserver
  $installer.WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
}
. "$PSScriptRoot/wix.ps1"
$source = Get-Content -Raw packaging/runquota_dist.nim
$upgradeCode = [regex]::Match($source, 'RunQuotaUpgradeCode\*\s*=\s*"([^"]+)"').Groups[1].Value
if (-not $upgradeCode) { throw 'Canonical package UpgradeCode is absent' }
$manifest = Get-Content -Raw .github/release.json | ConvertFrom-Json
$targets = @($manifest.targets | Where-Object { $_.id.StartsWith('windows-') })
if ($targets.Count -ne 2) { throw 'Both Windows targets must be verified' }
New-Item -ItemType Directory -Force test-logs | Out-Null
foreach ($target in $targets) {
  $id = $target.id
  $stem = "runquota-$Version-$id"
  $msi = (Resolve-Path (Join-Path $Dist "$stem.msi")).Path
  $originalHash = (Get-FileHash $msi -Algorithm SHA256).Hash
  & "$ReleaseWixDir/smoke.exe" -nologo $msi
  if ($LASTEXITCODE -ne 0) { throw "MSI ICE validation failed: $id" }
  & "$PSScriptRoot/../verify_windows_package.ps1" -MsiPath $msi -ExpectedVersion $Version -ExpectedUpgradeCode $upgradeCode
  if ($LASTEXITCODE -ne 0) { throw "MSI table verification failed: $id" }
  $work = Join-Path $env:RUNNER_TEMP ("runquota-msi-check-" + [guid]::NewGuid())
  New-Item -ItemType Directory $work | Out-Null
  $checkError = $null
  try {
    $extract = Join-Path $work 'msi'
    $log = Join-Path (Resolve-Path test-logs).Path "$id-msi-extraction.log"
    $process = [Diagnostics.Process]::new()
    $process.StartInfo.FileName = 'msiexec.exe'
    $process.StartInfo.UseShellExecute = $false
    foreach ($argument in @('/a', $msi, '/qn', '/l*v', $log, "TARGETDIR=$extract")) {
      $process.StartInfo.ArgumentList.Add($argument)
    }
    try {
      if (-not $process.Start()) { throw 'Could not start Windows Installer' }
      if (-not $process.WaitForExit(120000)) {
        $process.Kill($true)
        $process.WaitForExit()
        throw "MSI extraction timed out: $id"
      }
      Write-Host "MSI extraction: $id, exit=$($process.ExitCode)"
      if ($process.ExitCode -ne 0) { throw "MSI extraction failed: $id, exit=$($process.ExitCode)" }
    } finally { $process.Dispose() }
    $client = @(Get-ChildItem $extract -Recurse -Filter runquota.exe)
    if ($client.Count -ne 1) { throw 'MSI does not extract exactly one client' }
    $prefix = Split-Path (Split-Path $client[0].FullName -Parent) -Parent
    $zipRoot = Join-Path $work 'zip'
    Expand-Archive -LiteralPath (Join-Path $Dist "$stem.zip") -DestinationPath $zipRoot
    # Compare every shipped payload file, including licenses and any DLLs,
    # against the archive whose executable bytes passed native smoke tests.
    $archivePrefix = Join-Path $zipRoot $stem
    foreach ($file in Get-ChildItem $archivePrefix -Recurse -File) {
      $relative = [IO.Path]::GetRelativePath($archivePrefix, $file.FullName)
      $installed = Join-Path $prefix $relative
      Write-Host "Comparing MSI payload: $id/$relative"
      if (-not (Test-Path -LiteralPath $installed -PathType Leaf) -or
          (Get-FileHash $installed -Algorithm SHA256).Hash -ne (Get-FileHash $file.FullName -Algorithm SHA256).Hash) {
        throw "MSI payload differs from the native-tested ZIP: $id/$relative"
      }
    }
    $savedPath = $env:PATH
    try {
      $env:PATH = "$env:SystemRoot\System32;$env:SystemRoot"
      Write-Host "Running extracted MSI payload: $id"
      & $env:RELEASE_NODE "$PSScriptRoot/smoke.cjs" $prefix $id
      if ($LASTEXITCODE -ne 0) { throw "Extracted MSI smoke check failed: $id" }
    } finally { $env:PATH = $savedPath }
    if ((Get-FileHash $msi -Algorithm SHA256).Hash -ne $originalHash) {
      throw "MSI validation changed the release bytes: $id"
    }
  } catch {
    # Cleanup must not hide the check that failed (for example a file lock or
    # access error). Keep the original exception and its script location.
    $checkError = $_
    Write-Host ($_ | Format-List * -Force | Out-String)
    throw
  } finally {
    for ($cleanupAttempt = 0; $cleanupAttempt -lt 5; $cleanupAttempt++) {
      try {
        Remove-Item -LiteralPath $work -Recurse -Force
        break
      } catch {
        if ($cleanupAttempt -eq 4) {
          if ($null -eq $checkError) { throw }
          Write-Warning "MSI scratch cleanup also failed: $_"
        } else { Start-Sleep -Milliseconds 500 }
      }
    }
  }
}
