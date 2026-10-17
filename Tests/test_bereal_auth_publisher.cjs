'use strict';
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { publishPublicChallenge, cleanupPublicTransport } = require('../scripts/bereal-auth-publish-challenge.cjs');
const key = crypto.generateKeyPairSync('rsa', { modulusLength: 3072 }).publicKey;
const env = {
  GITHUB_REPOSITORY: '444yttt/Y3POSClient', GITHUB_REF: 'refs/heads/main',
  GITHUB_ACTIONS: 'true', GITHUB_RUN_ID: '1234', GITHUB_SHA: 'a'.repeat(40),
  BEREAL_CHALLENGE_GITHUB_TOKEN: 'synthetic-ci-token'
};
const challenge = {
  version: 1, purpose: 'bereal-apple-auth', run_id: '1234', phase: 0,
  nonce: 'b'.repeat(64), expires_at: Math.floor(Date.now() / 1000) + 1200,
  public_key_spki_pem: key.export({ type: 'spki', format: 'pem' }), allowed_payload: 'credentials'
};
challenge.context_b64 = Buffer.from(`BeReal493AppleAuthRelayV1|1234|0|${challenge.nonce}|${challenge.expires_at}`).toString('base64');
function fake(responses) {
  const calls = [];
  const fetcher = async (url, options) => {
    calls.push({ url, options });
    assert(url.startsWith('https://api.github.com/repos/444yttt/Y3POSClient/'));
    assert.equal(options.redirect, 'error');
    assert.equal(options.headers.Authorization, 'Bearer synthetic-ci-token');
    const [status, data] = responses.shift();
    return { status, ok: status >= 200 && status < 300, json: async () => data };
  };
  return { calls, fetcher };
}
(async () => {
  let count = 0;
  for (const replacement of [
    { GITHUB_REPOSITORY: 'other/repo' }, { GITHUB_REF: 'refs/heads/feature' },
    { GITHUB_RUN_ID: '../1234' }, { GITHUB_ACTIONS: 'false' },
    { GITHUB_SHA: 'not-a-commit' }, { BEREAL_CHALLENGE_GITHUB_TOKEN: '' }
  ]) {
    const x = fake([]);
    await assert.rejects(publishPublicChallenge(challenge, { ...env, ...replacement }, x.fetcher));
    assert.equal(x.calls.length, 0); count++;
  }
  for (const replacement of [{ apple_id: 'synthetic@example.invalid' }, { password: 'not-a-real-password' }, { run_id: '9999' }]) {
    const x = fake([]);
    await assert.rejects(publishPublicChallenge({ ...challenge, ...replacement }, env, x.fetcher));
    assert.equal(x.calls.length, 0); count++;
  }
  const fresh = fake([[404, null], [201, {}], [404, null], [201, {}]]);
  await publishPublicChallenge(challenge, env, fresh.fetcher);
  assert.deepEqual(fresh.calls.map(x => x.options.method), ['GET', 'POST', 'GET', 'PUT']);
  assert.deepEqual(JSON.parse(fresh.calls[1].options.body), { ref: 'refs/heads/bereal-auth-challenges-1234', sha: env.GITHUB_SHA });
  const put = JSON.parse(fresh.calls[3].options.body);
  assert.equal(put.branch, 'bereal-auth-challenges-1234');
  assert.deepEqual(JSON.parse(Buffer.from(put.content, 'base64')), challenge); count++;
  const existing = fake([[200, { ref: 'refs/heads/bereal-auth-challenges-1234' }], [200, { sha: 'c'.repeat(40) }], [200, {}]]);
  await publishPublicChallenge(challenge, env, existing.fetcher);
  assert.deepEqual(existing.calls.map(x => x.options.method), ['GET', 'GET', 'PUT']);
  assert.equal(JSON.parse(existing.calls[2].options.body).sha, 'c'.repeat(40)); count++;
  const other = fake([[200, { ref: 'refs/heads/main' }]]);
  await assert.rejects(publishPublicChallenge(challenge, env, other.fetcher));
  assert.equal(other.calls.length, 1); count++;
  const denied = fake([[403, null]]);
  await assert.rejects(publishPublicChallenge(challenge, env, denied.fetcher));
  assert.equal(denied.calls.length, 1); count++;
  const cleanup = fake([[204, null], [404, null]]);
  await cleanupPublicTransport(env, cleanup.fetcher);
  assert.deepEqual(cleanup.calls.map(x => x.url.split('/Y3POSClient/')[1]),
    ['git/refs/heads/bereal-auth-challenges-1234', 'git/refs/heads/bereal-auth-replies-1234']);
  assert(cleanup.calls.every(x => x.options.method === 'DELETE' && x.options.body === undefined)); count++;
  console.log(`${count} scoped public-challenge tests passed; no network or authentication`);
})().catch(() => { process.stderr.write('Public-challenge tests failed.\n'); process.exitCode = 1; });
