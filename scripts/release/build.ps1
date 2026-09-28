param([Parameter(Mandatory = $true)][string]$Target)
. "$env:RELEASE_TOOLS/common.ps1"
Get-ReleaseDependency 'nim-shm-lease' 'SHM_LEASE_SRC'
foreach ($line in Get-Content apps/entrypoints.txt) {
  if (-not $line.Trim() -or $line.StartsWith('#')) { continue }
  $parts = $line -split '\s+'
  Invoke-ReleaseNim $parts[1] "$ReleaseStage/bin/$($parts[0]).exe"
}
Copy-Item LICENSE $ReleaseStage
Get-ReleaseDependency 'release-packaging-src' 'REPROBUILD_SRC' ''
Get-ReleaseDependency 'release-nimcrypto-src' 'NIMCRYPTO_SRC' ''
Get-ReleaseDependency 'release-bearssl-src' 'BEARSSL_SRC' ''
Invoke-ReleaseNim 'packaging/release_metadata.nim' 'build/release-metadata.exe' @('-d:reproVendoredHash')
& ./build/release-metadata.exe $Target $ReleaseStage build/release-authoring
if ($LASTEXITCODE -ne 0) { throw 'Distribution rendering failed' }
Complete-Release
