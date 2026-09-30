// Exercise the real packaged client and daemon over an isolated local endpoint.
// No mocks: the acquired command is a real child process with a checked exit code.
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const cp = require('node:child_process');
const assert = require('node:assert/strict');
const [root, target] = process.argv.slice(2);
const suffix = target.startsWith('windows') ? '.exe' : '';
const cli = path.join(root, 'bin/runquota' + suffix);
const daemon = path.join(root, 'bin/runquotad' + suffix);
const work = fs.mkdtempSync(path.join(os.tmpdir(), 'rq-'));
const endpoint = path.join(work, 'daemon.sock');
const env = {...process.env, RUNQUOTA_SOCKET: endpoint};
const run = (...args) => cp.execFileSync(cli, args, {env, encoding: 'utf8', timeout: 30000});
async function main() {
  assert.match(run('--version'), /^runquota \d+\.\d+\.\d+/);
  assert.match(cp.execFileSync(daemon, ['--version'], {encoding: 'utf8'}), /^runquotad \d+\.\d+\.\d+/);
  let logs = '';
  const child = cp.spawn(daemon, ['--socket', endpoint, '--cpu-milli', '2000',
    '--memory-bytes', '268435456', '--memory-pressure-source', 'unavailable',
    '--no-write-stats', '--estimate-db', path.join(work, 'estimates'),
    '--observation-db', path.join(work, 'observations'), '--host-identity-file', path.join(work, 'host')], {env});
  child.stdout.on('data', b => { logs += b; });
  child.stderr.on('data', b => { logs += b; });
  try {
    let ready = false;
    for (let i = 0; i < 100; i++) {
      if (child.exitCode !== null) throw new Error(`daemon exited: ${logs}`);
      try { JSON.parse(run('status', '--json')); ready = true; break; } catch {}
      await new Promise(resolve => setTimeout(resolve, 100));
    }
    assert(ready, `daemon did not become ready: ${logs}`);
    const leased = cp.spawnSync(cli, ['acquire', '--cpu', '1', '--mem', '16777216',
      '--', process.execPath, '-e', 'process.stdout.write("release-lease-ok"); process.exit(7)'],
    {env, encoding: 'utf8', timeout: 30000});
    assert.equal(leased.status, 7, JSON.stringify(leased));
    assert.match(leased.stdout, /release-lease-ok/);
    JSON.parse(run('leases', '--json'));
  } finally {
    child.kill();
    await new Promise(resolve => child.exitCode !== null ? resolve() : child.once('exit', resolve));
    fs.rmSync(work, {recursive: true, force: true});
  }
}
main().catch(e => { console.error(e); process.exitCode = 1; });
