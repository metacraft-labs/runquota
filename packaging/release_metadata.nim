## Export package authoring from RunQuota's existing Distribution. The release
## workflow supplies an already verified tree; no parallel service definition.
import std/[json, os, strutils]
import repro_dsl_stdlib/packaging
import ./runquota_dist

let args = commandLineParams()
if args.len != 3:
  quit("usage: release_metadata TARGET PAYLOAD OUTPUT-DIRECTORY", 2)
let target = args[0]
let targetOs = if target.startsWith("windows-"): toWindows
               elif target.startsWith("darwin-"): toDarwin else: toLinux
let arch = target.split('-')[^1]
let root = absolutePath(args[1]).replace('\\', '/')
let output = args[2]
createDir(output)
var dist = newRunQuotaDistribution(RunQuotaPackageVersion, targetOs,
  architecture = arch, prefix = (if targetOs == toWindows: "" else: "/usr"))
let suffix = if targetOs == toWindows: ".exe" else: ""
dist.components = @[
  executableComponent(root / ("bin/runquota" & suffix)),
  executableComponent(root / ("bin/runquotad" & suffix)),
  component(crDataFile, root / "LICENSE")]
var tree = StagedTree(dist: dist, root: root)
for file in walkDirRec(root):
  let rel = relativePath(file, root).replace('\\', '/')
  let executable = rel in ["bin/runquota" & suffix, "bin/runquotad" & suffix]
  tree.files.add(StagedFile(rootRelPath: rel,
    role: (if executable: crExecutable else: crDataFile), isPublicEntryPoint: executable))
writeFile(output / "distribution.json", pretty(%*{
  "name": dist.name, "version": dist.version, "license": dist.metadata.license,
  "summary": dist.metadata.summary, "upgradeCode": dist.metadata.upgradeCode,
  "serviceName": RunQuotaDaemonServiceName}) & "\n")
case targetOs
of toWindows:
  writeFile(output / "runquota.wxs", wxsText(dist, tree))
  writeFile(output / "scoop.json", scoopManifestText(dist, tree))
of toLinux:
  writeFile(output / "runquotad.service", systemdUnitText(dist, dist.services[0]))
  writeFile(output / "PKGINFO", archPkgInfoText(dist))
else: discard
