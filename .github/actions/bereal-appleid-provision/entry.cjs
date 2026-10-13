'use strict';
const { spawnSync } = require('node:child_process');
const path = require('node:path');
if (process.env.GITHUB_REPOSITORY !== '444yttt/Y3POSClient' ||
    process.env.GITHUB_REF !== 'refs/heads/main') {
  process.stderr.write('Apple authentication is restricted to the authorized main repository.\n');
  process.exit(1);
}
const script = path.join(process.env.GITHUB_WORKSPACE, 'scripts/bereal-appleid-provision.py');
const result = spawnSync('python3', [script], {
  stdio: 'inherit', env: { ...process.env, BEREAL_NODE_EXECUTABLE: process.execPath }
});
process.exitCode = Number.isInteger(result.status) ? result.status : 1;
