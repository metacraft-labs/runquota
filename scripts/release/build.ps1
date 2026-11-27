param([Parameter(Mandatory = $true)][string]$Target)
. "$env:RELEASE_TOOLS/common.ps1"
Get-ReleaseDependency 'nim-shm-lease' 'SHM_LEASE_SRC'
foreach ($line in Get-Content apps/entrypoints.txt) {
  if (-not $line.Trim() -or $line.StartsWith('#')) { continue }
  $parts = $line -split '\s+'
  Invoke-ReleaseNim $parts[1] "$ReleaseStage/bin/$($parts[0]).exe"
}
Copy-Item LICENSE $ReleaseStage
# The package renderers come from the Reprobuild that pins/reprobuild.json
# names, read at the metacraft-github-actions revision flake.lock records:
# the same source flake.nix's RELEASE_PACKAGING_SRC is.
Get-ReleaseDependency 'metacraft-github-actions' 'RELEASE_PINS_SRC' ''
$reprobuildPin = Get-Content -Raw "$env:RELEASE_PINS_SRC/pins/reprobuild.json" | ConvertFrom-Json
if ($reprobuildPin.rev -notmatch '^[a-f0-9]{40}$') { throw 'Unpinned dependency reprobuild' }
$reprobuildSrc = Join-Path (Get-Location) 'build/release-deps/reprobuild'
if (Test-Path $reprobuildSrc) { Remove-Item -Recurse -Force $reprobuildSrc }
& git init --quiet $reprobuildSrc
if ($LASTEXITCODE -ne 0) { throw 'Cannot initialize reprobuild' }
& git -C $reprobuildSrc remote add origin "https://github.com/$($reprobuildPin.owner)/$($reprobuildPin.repo).git"
if ($LASTEXITCODE -ne 0) { throw 'Cannot configure reprobuild origin' }
& git -C $reprobuildSrc fetch --quiet --depth=1 origin $reprobuildPin.rev
if ($LASTEXITCODE -ne 0) { throw 'Cannot fetch reprobuild' }
& git -C $reprobuildSrc checkout --quiet --detach FETCH_HEAD
if ($LASTEXITCODE -ne 0) { throw "Cannot check out reprobuild@$($reprobuildPin.rev)" }
$env:REPROBUILD_SRC = $reprobuildSrc
# nim-cli-spec at the revision the pinned Reprobuild's own flake.lock records
# (flake.nix's RELEASE_CLI_SPEC_SRC). Get-ReleaseDependency reads the
# flake.lock of the current directory, so it runs inside that checkout.
Push-Location $reprobuildSrc
try { Get-ReleaseDependency 'nim-cli-spec-src' 'CLI_SPEC_SRC' }
finally { Pop-Location }
Get-ReleaseDependency 'release-nimcrypto-src' 'NIMCRYPTO_SRC' ''
Get-ReleaseDependency 'release-bearssl-src' 'BEARSSL_SRC' ''
Invoke-ReleaseNim 'packaging/release_metadata.nim' 'build/release-metadata.exe' @('-d:reproVendoredHash')
& ./build/release-metadata.exe $Target $ReleaseStage build/release-authoring
if ($LASTEXITCODE -ne 0) { throw 'Distribution rendering failed' }
Complete-Release
