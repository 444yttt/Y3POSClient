'use strict';
const { spawnSync } = require('node:child_process');
const path = require('node:path');
const script = path.join(process.env.GITHUB_WORKSPACE, 'scripts/bereal-appleid-provision.py');
const result = spawnSync('python3', [script, '--cleanup-private-state'],
  { stdio: 'inherit', env: process.env });
if (result.status !== 0) {
  process.stderr.write('Scoped authentication cleanup did not complete; the disposable CI runner will be discarded.\n');
  process.exitCode = 1;
}
