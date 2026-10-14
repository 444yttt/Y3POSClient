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

function authorizedEnvironment(env) {
  if (env.GITHUB_REPOSITORY !== '444yttt/Y3POSClient' ||
      env.GITHUB_REF !== 'refs/heads/main' || env.GITHUB_ACTIONS !== 'true' ||
      !/^[0-9]{1,24}$/.test(env.GITHUB_RUN_ID || '') ||
      !/^[a-f0-9]{40}$/.test(env.GITHUB_SHA || '') ||
      !env.BEREAL_CHALLENGE_GITHUB_TOKEN) {
    throw new Error('Public challenge publication is restricted to authorized CI');
  }
}

async function githubRequest(env, method, suffix, body, fetcher = fetch) {
  const response = await fetcher(`https://api.github.com/repos/444yttt/Y3POSClient/${suffix}`, {
    method, redirect: 'error', signal: AbortSignal.timeout(20000),
    headers: {
      Authorization: `Bearer ${env.BEREAL_CHALLENGE_GITHUB_TOKEN}`,
      Accept: 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
      'Content-Type': 'application/json'
    }, ...(body === undefined ? {} : { body: JSON.stringify(body) })
  });
  if (response.status === 404 && (method === 'GET' || method === 'DELETE')) return null;
  if (!response.ok) throw new Error('Scoped public challenge operation failed');
  return response.status === 204 ? null : response.json();
}

async function publishPublicChallenge(challenge, env = process.env, fetcher = fetch) {
  authorizedEnvironment(env);
  validate(challenge);
  if (challenge.run_id !== env.GITHUB_RUN_ID) throw new Error('Challenge run mismatch');
  const branch = `bereal-auth-challenges-${env.GITHUB_RUN_ID}`;
  const suffix = `git/ref/heads/${branch}`;
  const existing = await githubRequest(env, 'GET', suffix, undefined, fetcher);
  if (existing === null) {
    await githubRequest(env, 'POST', 'git/refs', {
      ref: `refs/heads/${branch}`, sha: env.GITHUB_SHA
    }, fetcher);
  } else if (existing.ref !== `refs/heads/${branch}`) {
    throw new Error('Unexpected challenge branch');
  }
  const file = 'contents/ci-auth-challenge/current.json';
  const previous = await githubRequest(env, 'GET', `${file}?ref=${branch}`, undefined, fetcher);
  if (previous !== null && !/^[a-f0-9]{40}$/.test(previous.sha || '')) {
    throw new Error('Unexpected public challenge file');
  }
  await githubRequest(env, 'PUT', file, {
    message: `Publish public Apple authentication challenge phase ${challenge.phase}`,
    branch, content: Buffer.from(JSON.stringify(challenge) + '\n').toString('base64'),
    ...(previous === null ? {} : { sha: previous.sha })
  }, fetcher);
}

async function cleanupPublicTransport(env = process.env, fetcher = fetch) {
  authorizedEnvironment(env);
  for (const prefix of ['bereal-auth-challenges-', 'bereal-auth-replies-']) {
    await githubRequest(env, 'DELETE', `git/refs/heads/${prefix}${env.GITHUB_RUN_ID}`, undefined, fetcher);
  }
}

async function main() {
  if (process.argv[2] === '--cleanup' && process.argv.length === 3) {
    await cleanupPublicTransport();
    process.stdout.write('Scoped public authentication transport cleanup finished.\n');
    return;
  }
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
  await publishPublicChallenge(challenge);
  const modulePath = process.env.BEREAL_ARTIFACT_MODULE_PATH;
  if (!modulePath) throw new Error('Artifact publisher module is unavailable');
  const { DefaultArtifactClient } = require(modulePath);
  const client = new DefaultArtifactClient();
  const result = await client.uploadArtifact(
    `BeReal493-AppleAuth-${challenge.run_id}-${challenge.phase}`,
    [file], path.dirname(file), { retentionDays: 1 });
  process.stdout.write(JSON.stringify({ artifact_id: result.id, phase: challenge.phase }) + '\n');
}

module.exports = { validate, publishPublicChallenge, cleanupPublicTransport };
if (require.main === module) main().catch(() => {
  process.stderr.write('Public authentication challenge upload failed.\n');
  process.exitCode = 1;
});
