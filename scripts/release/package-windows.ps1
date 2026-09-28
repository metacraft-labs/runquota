param(
  [Parameter(Mandatory = $true)][string]$Target,
  [Parameter(Mandatory = $true)][string]$Version,
  [Parameter(Mandatory = $true)][string]$Output
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. "$PSScriptRoot/wix.ps1"
$arch = if ($Target.EndsWith('aarch64')) { 'arm64' } else { 'x64' }
& "$ReleaseWixDir/candle.exe" -nologo -arch $arch -ext WixUtilExtension `
  -out build/release-authoring/runquota.wixobj build/release-authoring/runquota.wxs
if ($LASTEXITCODE -ne 0) { throw 'MSI authoring compilation failed' }
# ICE validation is mandatory in release-tools.yml's verify-msi job, which
# validates these transferred bytes with smoke.exe before assembly/signing.
# The shared x64 runner's service account cannot execute Installer actions.
& "$ReleaseWixDir/light.exe" -nologo -sval -ext WixUtilExtension `
  -pdbout build/release-authoring/runquota.wixpdb -out $Output build/release-authoring/runquota.wixobj
if ($LASTEXITCODE -ne 0) { throw 'MSI linking failed' }
$metadata = Get-Content -Raw build/release-authoring/distribution.json | ConvertFrom-Json
& ./scripts/verify_windows_package.ps1 -MsiPath $Output -ExpectedVersion $Version -ExpectedUpgradeCode $metadata.upgradeCode
if ($LASTEXITCODE -ne 0) { throw 'MSI table verification failed' }
