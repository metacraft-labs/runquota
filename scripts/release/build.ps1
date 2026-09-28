param([Parameter(Mandatory = $true)][string]$Target)
. "$env:RELEASE_TOOLS/common.ps1"
Get-ReleaseDependency 'nim-shm-lease' 'SHM_LEASE_SRC'
foreach ($line in Get-Content apps/entrypoints.txt) {
  if (-not $line.Trim() -or $line.StartsWith('#')) { continue }
  $parts = $line -split '\s+'
  Invoke-ReleaseNim $parts[1] "$ReleaseStage/bin/$($parts[0]).exe"
}
Copy-Item LICENSE $ReleaseStage
Complete-Release
