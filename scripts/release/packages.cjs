// RunQuota's extra Windows formats share the verified archive payload and the
// authoring emitted by packaging/runquota_dist.nim through reprobuild.
module.exports = ({target, dist, plan, run, digest}) => {
  if (!target.startsWith('windows-')) return;
  const fs = require('node:fs');
  const path = require('node:path');
  const names = plan.matrix.find(t => t.id === target).assets;
  const archive = names.find(n => n.endsWith('.zip'));
  const msi = names.find(n => n.endsWith('.msi'));
  const scoop = names.find(n => n.endsWith('-scoop.json'));
  run('pwsh', ['-NoProfile', '-File', 'scripts/release/package-windows.ps1',
    '-Target', target, '-Version', plan.version, '-Output', path.join(dist, msi)]);
  const manifest = JSON.parse(fs.readFileSync('build/release-authoring/scoop.json'));
  const key = target.endsWith('aarch64') ? 'arm64' : '64bit';
  manifest.architecture[key].url = `https://github.com/metacraft-labs/runquota/releases/download/v${plan.version}/${archive}`;
  manifest.architecture[key].hash = digest(path.join(dist, archive));
  manifest.extract_dir = `runquota-${plan.version}-${target}`;
  fs.writeFileSync(path.join(dist, scoop), JSON.stringify(manifest, null, 2) + '\n');
};
