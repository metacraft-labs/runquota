param(
  [Parameter(Mandatory = $true)][string]$Target,
  [Parameter(Mandatory = $true)][string]$Version,
  [Parameter(Mandatory = $true)][string]$Output
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$toolsDir = Join-Path $env:RUNNER_TEMP 'release-wix3'
$zip = "$toolsDir.zip"
Invoke-WebRequest 'https://github.com/wixtoolset/wix3/releases/download/wix3141rtm/wix314-binaries.zip' -OutFile $zip
if ((Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant() -ne '6ac824e1642d6f7277d0ed7ea09411a508f6116ba6fae0aa5f2c7daa2ff43d31') {
  throw 'WiX archive checksum mismatch'
}
Expand-Archive -LiteralPath $zip -DestinationPath $toolsDir -Force
$arch = if ($Target.EndsWith('aarch64')) { 'arm64' } else { 'x64' }
& "$toolsDir/candle.exe" -nologo -arch $arch -ext WixUtilExtension `
  -out build/release-authoring/runquota.wixobj build/release-authoring/runquota.wxs
if ($LASTEXITCODE -ne 0) { throw 'MSI authoring compilation failed' }
& "$toolsDir/light.exe" -nologo -ext WixUtilExtension `
  -pdbout build/release-authoring/runquota.wixpdb -out $Output build/release-authoring/runquota.wixobj
if ($LASTEXITCODE -ne 0) { throw 'MSI linking/validation failed' }
$metadata = Get-Content -Raw build/release-authoring/distribution.json | ConvertFrom-Json
& ./scripts/verify_windows_package.ps1 -MsiPath $Output -ExpectedVersion $Version -ExpectedUpgradeCode $metadata.upgradeCode
if ($LASTEXITCODE -ne 0) { throw 'MSI table verification failed' }
# Administrative extraction checks the actual embedded cabinet without
# registering or starting a host-wide service on the build machine.
$extract = Join-Path $env:RUNNER_TEMP "runquota-msi-$arch"
$msi = (Resolve-Path $Output).Path
$process = Start-Process msiexec.exe -ArgumentList @('/a', "`"$msi`"", '/qn', "TARGETDIR=`"$extract`"") -Wait -PassThru
if ($process.ExitCode -ne 0) { throw "MSI extraction failed: $($process.ExitCode)" }
$client = @(Get-ChildItem $extract -Recurse -Filter runquota.exe)
if ($client.Count -ne 1) { throw 'MSI does not extract exactly one client' }
$prefix = Split-Path (Split-Path $client[0].FullName -Parent) -Parent
$savedPath = $env:PATH
try {
  $env:PATH = "$env:SystemRoot\System32;$env:SystemRoot"
  & $env:RELEASE_NODE scripts/release/smoke.cjs $prefix $Target
  if ($LASTEXITCODE -ne 0) { throw 'Extracted MSI smoke check failed' }
} finally { $env:PATH = $savedPath }
