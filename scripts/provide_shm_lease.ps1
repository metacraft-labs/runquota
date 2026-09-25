# Provide `nim-shm-lease` at the revision `flake.lock` pins, for a Windows job.
#
# The Nix legs get it from the flake input, through `SHM_LEASE_SRC`. Windows
# has no Nix story here, and the published stats table's Windows arm imports
# `nim-shm-lease`'s anchor exactly as the POSIX arms do, so a bare Windows
# checkout of this repository cannot build `runquotad` without it. This clones
# the ONE revision the flake pins -- never a moving branch, so the Windows
# build and the Nix builds cannot disagree about which source they compiled --
# and exports `SHM_LEASE_SRC` for the rest of the job.
#
# usage: scripts/provide_shm_lease.ps1 -Destination <dir>
param(
  [Parameter(Mandatory = $true)][string]$Destination
)
$ErrorActionPreference = 'Stop'

$lock = Get-Content -Raw -LiteralPath flake.lock | ConvertFrom-Json
$node = $lock.nodes.'nim-shm-lease'.locked
if (-not $node -or -not $node.rev) {
  throw "flake.lock has no locked nim-shm-lease revision"
}
if (Test-Path -LiteralPath $Destination) {
  Remove-Item -Recurse -Force -LiteralPath $Destination
}
& git clone --quiet "https://github.com/$($node.owner)/$($node.repo).git" $Destination
if ($LASTEXITCODE -ne 0) { throw "git clone of $($node.owner)/$($node.repo) failed" }
& git -C $Destination checkout --quiet $node.rev
if ($LASTEXITCODE -ne 0) { throw "$($node.repo) has no revision $($node.rev)" }

$src = Join-Path (Resolve-Path -LiteralPath $Destination).Path "src"
if (-not (Test-Path -LiteralPath (Join-Path $src "shm_lease/anchor.nim"))) {
  throw "$($node.repo) at $($node.rev) has no src/shm_lease/anchor.nim"
}
if ($env:GITHUB_ENV) {
  Add-Content -Path $env:GITHUB_ENV -Value "SHM_LEASE_SRC=$src"
}
Write-Host "SHM_LEASE_SRC=$src ($($node.rev))"
