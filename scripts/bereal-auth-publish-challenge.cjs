#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

function validate(challenge) {
  const keys = new Set(['version', 'purpose', 'run_id', 'phase', 'nonce', 'expires_at',
    'public_key_spki_pem', 'context_b64', 'allowed_payload']);
  if (!challenge || Object.keys(challenge).some(k => !keys.has(k)) ||
      challenge.version !== 1 || challenge.purpose !== 'bereal-apple-auth' ||
      !/^[0-9]{1,24}$/.test(challenge.run_id) ||
      !Number.isInteger(challenge.phase) || challenge.phase < 0 || challenge.phase > 3 ||
      !/^[a-f0-9]{64}$/.test(challenge.nonce) ||
      !Number.isInteger(challenge.expires_at) ||
      challenge.expires_at <= Math.floor(Date.now() / 1000) ||
      challenge.expires_at > Math.floor(Date.now() / 1000) + 2700 ||
      challenge.allowed_payload !== (challenge.phase === 0 ? 'credentials' : 'two_factor')) {
    throw new Error('Invalid public authentication challenge');
  }
  const context = `BeReal493AppleAuthRelayV1|${challenge.run_id}|${challenge.phase}|${challenge.nonce}|${challenge.expires_at}`;
  if (Buffer.from(challenge.context_b64, 'base64').toString('utf8') !== context ||
      !/^-----BEGIN PUBLIC KEY-----/.test(challenge.public_key_spki_pem.trim()) ||
      /PRIVATE KEY/.test(challenge.public_key_spki_pem)) {
    throw new Error('Invalid public authentication key or context');
  }
  const publicKey = crypto.createPublicKey(challenge.public_key_spki_pem);
  if (publicKey.asymmetricKeyType !== 'rsa' || publicKey.asymmetricKeyDetails.modulusLength < 3072) {
    throw new Error('Invalid public authentication key type');
  }
  return challenge;
}

async function main() {
  const file = path.resolve(process.argv[2] || '');
  if (path.basename(file) !== 'challenge.json' || fs.statSync(file).size > 16384) {
    throw new Error('Only a bounded public challenge may be uploaded');
  }
  const challenge = validate(JSON.parse(fs.readFileSync(file, 'utf8')));
  if (challenge.run_id !== process.env.GITHUB_RUN_ID ||
      process.env.GITHUB_REPOSITORY !== '444yttt/Y3POSClient' ||
      process.env.GITHUB_REF !== 'refs/heads/main') {
    throw new Error('Authentication challenge does not match the authorized CI job');
  }
  const modulePath = process.env.BEREAL_ARTIFACT_MODULE_PATH;
  if (!modulePath) throw new Error('Artifact publisher module is unavailable');
  const { DefaultArtifactClient } = require(modulePath);
  const client = new DefaultArtifactClient();
  const result = await client.uploadArtifact(
    `BeReal493-AppleAuth-${challenge.run_id}-${challenge.phase}`,
    [file], path.dirname(file), { retentionDays: 1 });
  process.stdout.write(JSON.stringify({ artifact_id: result.id, phase: challenge.phase }) + '\n');
}

module.exports = { validate };
if (require.main === module) main().catch(() => {
  process.stderr.write('Public authentication challenge upload failed.\n');
  process.exitCode = 1;
});
