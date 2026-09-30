# Shared pinned WiX tools for linking and the independent MSI validation job.
$ReleaseWixDir = Join-Path $env:RUNNER_TEMP 'release-wix3'
$archive = "$ReleaseWixDir.zip"
Invoke-WebRequest 'https://github.com/wixtoolset/wix3/releases/download/wix3141rtm/wix314-binaries.zip' -OutFile $archive
if ((Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne '6ac824e1642d6f7277d0ed7ea09411a508f6116ba6fae0aa5f2c7daa2ff43d31') {
  throw 'WiX archive checksum mismatch'
}
Expand-Archive -LiteralPath $archive -DestinationPath $ReleaseWixDir -Force
