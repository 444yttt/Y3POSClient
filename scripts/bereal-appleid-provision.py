#!/usr/bin/env python3
"""Ephemeral, encrypted Apple login relay inside the authorized macOS CI job.

Only public challenges and a fixed-field result may leave this process. Apple
credentials are decrypted on the runner, sent to an isolated worker and removed
with its session directory. Existing CI signing secrets are not changed.
"""
from __future__ import annotations

import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import secrets
import select
import signal
import stat
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

PURPOSE = 'bereal-apple-auth'
CONTEXT_PREFIX = 'BeReal493AppleAuthRelayV1'
REPOSITORY = '444yttt/Y3POSClient'
ROOT_ID = 'com.ayato.bereal493'
IDENTIFIERS = tuple(ROOT_ID + suffix for suffix in (
    '', '.iMessageExtension', '.RealMojiNotificationContentExtension',
    '.NotificationServiceExtension', '.Widgets'))
MAX_PACKET_BYTES = 16384
MAX_CONTROL_BYTES = 8192
MAX_DURATION_SECONDS = 2400
OTP_DURATION_SECONDS = 600
POLL_SECONDS = 5
STATE_MARKER = '.bereal-auth-state.json'
ENVELOPE_FIELDS = frozenset(('version', 'run_id', 'phase', 'nonce', 'expires_at',
                             'wrapped_key', 'iv', 'ciphertext'))
FAILURE_REASONS = frozenset((
    'authentication_failed', 'invalid_credentials', 'invalid_context',
    'team_not_found', 'team_mismatch', 'certificate_not_found',
    'certificate_mismatch', 'device_count_mismatch', 'bundle_scope_mismatch',
    'provisioning_failed', 'worker_failed', 'two_factor_failed',
    'two_factor_input_invalid', 'two_factor_attempts_exhausted',
    'unsupported_authentication', 'agreement_review_required',
    'relay_initialization_failed', 'relay_cancelled', 'relay_transport_failed',
    'challenge_timeout', 'challenge_publish_failed', 'worker_protocol_invalid',
    'profiles_verification_failed'))
FAILURE_REASONS = FAILURE_REASONS | frozenset((
    'invalid_private_input', 'control_unavailable', 'two_factor_attempt_limit',
    'two_factor_timeout', 'two_factor_input_rejected', 'agreement_status_unavailable',
    'ambiguous_bundle', 'bundle_mismatch', 'profile_verification_failed',
    'permission_denied', 'apple_service_unavailable', 'interrupted', 'worker_setup_failed'))


class RelayError(RuntimeError):
    def __init__(self, reason: str):
        self.reason = reason if reason in FAILURE_REASONS else 'worker_failed'
        super().__init__(self.reason)


def strict_json(data: bytes | str, limit: int = MAX_PACKET_BYTES):
    if len(data.encode('utf-8') if isinstance(data, str) else data) > limit:
        raise ValueError('JSON exceeds bound')

    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError('Duplicate JSON field')
            result[key] = value
        return result

    return json.loads(data, object_pairs_hook=pairs,
                      parse_constant=lambda value: (_ for _ in ()).throw(ValueError('Nonfinite JSON')))


def write_private(path: Path, content: bytes):
    with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'wb') as stream:
        stream.write(content)
    return path


def write_cleanup_state(root: Path, run_id: str, worker_pgid=None):
    state = {'version': 1, 'purpose': PURPOSE, 'run_id': run_id,
             'worker_pgid': worker_pgid}
    temporary = root / (STATE_MARKER + '.tmp')
    write_private(temporary, json.dumps(state).encode())
    temporary.replace(root / STATE_MARKER)


def cleanup_private_state(runner_temp: Path, run_id: str):
    """Post-action fallback: remove only this run's marked private directories."""
    validate_run_id(run_id)
    for root in runner_temp.glob('bereal-apple-auth-*'):
        try:
            info = root.lstat()
            if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
                continue
            marker = root / STATE_MARKER
            marker_info = marker.lstat()
            if not stat.S_ISREG(marker_info.st_mode) or marker_info.st_size > 1024 or stat.S_IMODE(marker_info.st_mode) != 0o600:
                continue
            state = strict_json(marker.read_bytes(), 1024)
            if (set(state) != {'version', 'purpose', 'run_id', 'worker_pgid'}
                    or state['version'] != 1 or state['purpose'] != PURPOSE or state['run_id'] != run_id):
                continue
            pgid = state['worker_pgid']
            if pgid is not None:
                if type(pgid) is not int or pgid <= 1:
                    continue
                # Do not signal a reused PID or unrelated runner process. The
                # worker command must name its scoped script and this private
                # context directory, and still be its own process-group leader.
                probe = subprocess.run(['ps', '-o', 'command=', '-p', str(pgid)], capture_output=True, timeout=5)
                expected_context = str(root / 'apple-context.json').encode()
                if (probe.returncode == 0 and b'bereal-appleid-provision.rb' in probe.stdout
                        and expected_context in probe.stdout and os.getpgid(pgid) == pgid):
                    os.killpg(pgid, signal.SIGTERM)
                    for _ in range(10):
                        try:
                            os.kill(pgid, 0)
                        except ProcessLookupError:
                            break
                        time.sleep(0.1)
                    else:
                        os.killpg(pgid, signal.SIGKILL)
            __import__('shutil').rmtree(root)
        except (OSError, ValueError, TypeError, KeyError, subprocess.TimeoutExpired):
            # A matching active worker must never cause broad fallback deletion.
            continue


def encode(value: bytes) -> str:
    return base64.b64encode(value).decode('ascii')


def bounded_b64(value, minimum: int, maximum: int) -> bytes:
    if not isinstance(value, str) or len(value) > ((maximum + 2) // 3) * 4:
        raise ValueError('Invalid base64 bound')
    decoded = base64.b64decode(value, validate=True)
    if not minimum <= len(decoded) <= maximum or encode(decoded) != value:
        raise ValueError('Invalid base64 encoding')
    return decoded


def validate_run_id(run_id):
    if not isinstance(run_id, str) or not re.fullmatch(r'[0-9]{1,24}', run_id):
        raise RelayError('relay_initialization_failed')


class Challenge:
    def __init__(self, root: Path, run_id: str, phase: int, expires_at: int,
                 *, key=None, now=None):
        validate_run_id(run_id)
        clock = int(time.time() if now is None else now)
        if type(phase) is not int or phase not in range(4):
            raise ValueError('Invalid challenge phase')
        lifetime = MAX_DURATION_SECONDS if phase == 0 else OTP_DURATION_SECONDS
        if type(expires_at) is not int or not clock < expires_at <= clock + lifetime:
            raise ValueError('Invalid challenge lifetime')
        self.key = key or rsa.generate_private_key(public_exponent=65537, key_size=4096)
        if not isinstance(self.key, rsa.RSAPrivateKey) or self.key.key_size < 3072:
            raise ValueError('Invalid relay private key')
        nonce = secrets.token_hex(32)
        context = f'{CONTEXT_PREFIX}|{run_id}|{phase}|{nonce}|{expires_at}'.encode('utf-8')
        self.context = context
        self.public = {
            'version': 1, 'purpose': PURPOSE, 'run_id': run_id, 'phase': phase,
            'nonce': nonce, 'expires_at': expires_at,
            'public_key_spki_pem': self.key.public_key().public_bytes(
                serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo).decode('ascii'),
            'context_b64': encode(context),
            'allowed_payload': 'credentials' if phase == 0 else 'two_factor'}
        self.key_path = write_private(root / f'relay-key-{phase}.pem', self.key.private_bytes(
            serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption()))
        self.consumed = False

    def close(self):
        self.key_path.unlink(missing_ok=True)
        self.key = None

    def decrypt(self, packet, *, now=None):
        if self.consumed or self.key is None:
            raise ValueError('Challenge already consumed')
        clock = int(time.time() if now is None else now)
        if clock >= self.public['expires_at']:
            raise ValueError('Challenge expired')
        if not isinstance(packet, dict) or set(packet) != ENVELOPE_FIELDS:
            raise ValueError('Invalid envelope shape')
        for field in ('version', 'run_id', 'phase', 'nonce', 'expires_at'):
            expected = self.public[field]
            if type(packet[field]) is not type(expected) or packet[field] != expected:
                raise ValueError('Envelope challenge mismatch')
        wrapped = bounded_b64(packet['wrapped_key'], self.key.key_size // 8, self.key.key_size // 8)
        iv = bounded_b64(packet['iv'], 12, 12)
        ciphertext = bounded_b64(packet['ciphertext'], 17, 8192)
        key = self.key.decrypt(wrapped, padding.OAEP(
            mgf=padding.MGF1(hashes.SHA256()), algorithm=hashes.SHA256(), label=None))
        if len(key) != 32:
            raise ValueError('Invalid AES key')
        plaintext = AESGCM(key).decrypt(iv, ciphertext, self.context)
        payload = strict_json(plaintext, 4096)
        self.validate_payload(payload)
        self.consumed = True
        self.close()
        return payload

    def validate_payload(self, payload):
        if not isinstance(payload, dict):
            raise ValueError('Invalid payload')
        if self.public['phase'] == 0:
            if set(payload) != {'apple_id', 'password'}:
                raise ValueError('Invalid credentials fields')
            apple_id, password = payload['apple_id'], payload['password']
            if (not isinstance(apple_id, str) or not 3 <= len(apple_id.encode('utf-8')) <= 320
                    or apple_id != apple_id.strip() or any(ord(c) < 32 or ord(c) == 127 for c in apple_id)):
                raise ValueError('Invalid Apple login identifier')
            if (not isinstance(password, str) or not 1 <= len(password.encode('utf-8')) <= 2048
                    or '\0' in password):
                raise ValueError('Invalid password bound')
        elif set(payload) != {'code'} or not isinstance(payload['code'], str) or not re.fullmatch('[0-9]{6}', payload['code']):
            raise ValueError('Invalid verification code')


class NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class PublicReplyReader:
    def __init__(self, run_id: str):
        validate_run_id(run_id)
        self.base_url = (f'https://raw.githubusercontent.com/{REPOSITORY}/'
                         f'bereal-auth-replies-{run_id}/ci-auth-reply/current.json')
        self.opener = urllib.request.build_opener(NoRedirects())
        self.cache_nonce = secrets.token_hex(16)
        self.poll_index = 0

    def fetch(self):
        self.poll_index += 1
        url = self.base_url + f'?run_nonce={self.cache_nonce}&poll={self.poll_index}'
        req = urllib.request.Request(url, headers={'Cache-Control': 'no-cache', 'Accept': 'application/json'})
        try:
            with self.opener.open(req, timeout=10) as response:
                if response.geturl() != url:
                    raise RelayError('relay_transport_failed')
                data = response.read(MAX_PACKET_BYTES + 1)
                return strict_json(data)
        except urllib.error.HTTPError as error:
            if error.code in (404, 403, 429, 500, 502, 503, 504):
                return None
            raise RelayError('relay_transport_failed') from None
        except (urllib.error.URLError, TimeoutError, OSError, ValueError):
            return None


def wait_reply(challenge, reader, *, deadline, worker=None, sleeper=time.sleep,
               clock=time.time):
    seen = set()
    while clock() < min(deadline, challenge.public['expires_at']):
        if worker is not None and worker.poll() is not None:
            raise RelayError('worker_failed')
        packet = reader.fetch()
        if packet is not None:
            try:
                fingerprint = hashlib.sha256(json.dumps(packet, sort_keys=True).encode()).digest()
                if fingerprint not in seen:
                    if len(seen) >= 1000:
                        raise RelayError('relay_transport_failed')
                    seen.add(fingerprint)
                    return challenge.decrypt(packet, now=clock())
            except RelayError:
                raise
            except Exception:
                # A stale, malformed or unauthenticated public packet is never
                # an Apple input. Keep polling for a correctly encrypted reply.
                pass
        sleeper(min(POLL_SECONDS, max(0, min(deadline, challenge.public['expires_at']) - clock())))
    raise RelayError('challenge_timeout')


def publish_challenge(challenge, public_root: Path, publisher: Path):
    directory = public_root / f'phase-{challenge.public["phase"]}'
    directory.mkdir(mode=0o700)
    path = directory / 'challenge.json'
    path.write_text(json.dumps(challenge.public, indent=2) + '\n')
    try:
        result = subprocess.run([os.environ.get('BEREAL_NODE_EXECUTABLE', 'node'), str(publisher), str(path)],
                                capture_output=True, timeout=60, check=False)
        if result.returncode or len(result.stdout) > 65536:
            raise ValueError('Challenge publication failed')
        lines = result.stdout.splitlines()
        receipt = strict_json(lines[-1])
        artifact_id = receipt.get('artifact_id')
        if (type(artifact_id) is not int or not 0 < artifact_id < 10 ** 20
                or type(receipt.get('phase')) is not int or receipt['phase'] != challenge.public['phase']):
            raise ValueError('Invalid publication receipt')
    except Exception:
        raise RelayError('challenge_publish_failed') from None
    print(f'Public Apple authentication challenge ready: phase={challenge.public["phase"]} artifact_id={artifact_id}', flush=True)
    return artifact_id


def worker_environment(root: Path, fd: int):
    # The worker needs no GitHub token, P12, ASC key or CI secret. Gem search
    # paths preserve a runner installation without forwarding secret variables.
    permitted = ('PATH', 'HOME', 'LANG', 'LC_ALL', 'GEM_HOME', 'GEM_PATH',
                 'BUNDLE_GEMFILE', 'BUNDLE_PATH', 'RUBYOPT', 'SSL_CERT_FILE',
                 'GITHUB_REPOSITORY', 'GITHUB_REF')
    env = {name: os.environ[name] for name in permitted if name in os.environ}
    temporary = root / 'worker-temp'
    temporary.mkdir(mode=0o700)
    # HOME retains its existing meaning. The worker disables all Fastlane
    # cookie/session/service-key persistence, so no session is written there.
    env.update(TMPDIR=str(temporary), BEREAL_CONTROL_FD=str(fd),
               CI='true', FASTLANE_SKIP_UPDATE_CHECK='1',
               FASTLANE_HIDE_TIMESTAMP='1', FASTLANE_DISABLE_COLORS='1')
    return env


def start_worker(root: Path, credentials, context, worker_path: Path):
    credential_path = write_private(root / 'apple-credentials.json', json.dumps(credentials).encode('utf-8'))
    context_path = write_private(root / 'apple-context.json', json.dumps(context).encode('utf-8'))
    read_fd, write_fd = os.pipe()
    os.set_blocking(read_fd, False)
    try:
        worker = subprocess.Popen(['ruby', str(worker_path), str(credential_path), str(context_path)],
                                  stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                                  stderr=subprocess.DEVNULL, pass_fds=(write_fd,),
                                  env=worker_environment(root, write_fd), start_new_session=True)
    except Exception:
        os.close(read_fd)
        raise RelayError('worker_failed') from None
    finally:
        os.close(write_fd)
    return worker, read_fd


def validate_control(event):
    if not isinstance(event, dict) or not isinstance(event.get('event'), str):
        raise RelayError('worker_protocol_invalid')
    kind = event['event']
    if kind == 'two_factor_required':
        if (set(event) != {'event', 'attempt', 'challenge_nonce'}
                or type(event['attempt']) is not int or event['attempt'] not in range(1, 4)
                or not isinstance(event['challenge_nonce'], str)
                or not re.fullmatch('[0-9a-f]{64}', event['challenge_nonce'])):
            raise RelayError('worker_protocol_invalid')
    elif kind == 'provisioning_complete':
        fields = {'event', 'created_bundle_count', 'reused_bundle_count',
                  'created_profile_count', 'reused_profile_count',
                  'registered_device_count', 'provisioned_bundle_count', 'agreement_status_known'}
        if (set(event) != fields or type(event['agreement_status_known']) is not bool
                or any(type(event[field]) is not int or not 0 <= event[field] <= 5 for field in fields - {'event', 'agreement_status_known'})
                or event['created_bundle_count'] + event['reused_bundle_count'] != 5
                or event['created_profile_count'] + event['reused_profile_count'] != 5
                or event['registered_device_count'] != 1 or event['provisioned_bundle_count'] != 5):
            raise RelayError('worker_protocol_invalid')
    elif kind == 'agreement_review_required':
        if set(event) != {'event'}:
            raise RelayError('worker_protocol_invalid')
    elif kind == 'failure':
        if set(event) != {'event', 'reason'} or event['reason'] not in FAILURE_REASONS:
            raise RelayError('worker_protocol_invalid')
    else:
        raise RelayError('worker_protocol_invalid')
    return event


class ControlReader:
    def __init__(self, fd):
        self.fd = fd
        self.buffer = b''

    def next(self, worker, deadline):
        while time.time() < deadline:
            if b'\n' in self.buffer:
                line, self.buffer = self.buffer.split(b'\n', 1)
                try:
                    return validate_control(strict_json(line, MAX_CONTROL_BYTES))
                except (ValueError, TypeError, KeyError):
                    raise RelayError('worker_protocol_invalid') from None
            ready, _, _ = select.select([self.fd], [], [], min(1, max(0, deadline - time.time())))
            if ready:
                chunk = os.read(self.fd, MAX_CONTROL_BYTES + 1)
                if not chunk:
                    raise RelayError('worker_failed')
                self.buffer += chunk
                if len(self.buffer) > MAX_CONTROL_BYTES:
                    raise RelayError('worker_protocol_invalid')
            elif worker.poll() is not None:
                raise RelayError('worker_failed')
        raise RelayError('challenge_timeout')


def stop_worker(worker):
    if worker is None:
        return
    try:
        os.killpg(worker.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        worker.wait(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(worker.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        worker.wait(timeout=5)
    if worker.stdin is not None:
        worker.stdin.close()


def drive_worker(root, public_root, run_id, credentials, context, reader,
                 worker_path, publisher, deadline):
    worker, fd = None, None
    challenge = None
    try:
        worker, fd = start_worker(root, credentials, context, worker_path)
        write_cleanup_state(root, run_id, worker.pid)
        credentials.clear()
        control = ControlReader(fd)
        previous_nonce, phase = None, 0
        while True:
            event = control.next(worker, deadline)
            if event['event'] == 'two_factor_required':
                if event['attempt'] != phase + 1 or event['challenge_nonce'] == previous_nonce:
                    raise RelayError('worker_protocol_invalid')
                phase = event['attempt']
                previous_nonce = event['challenge_nonce']
                challenge = Challenge(root, run_id, phase, min(int(deadline), int(time.time()) + OTP_DURATION_SECONDS))
                publish_challenge(challenge, public_root, publisher)
                payload = wait_reply(challenge, reader, deadline=deadline, worker=worker)
                worker.stdin.write((json.dumps({'code': payload['code'], 'challenge_nonce': previous_nonce}) + '\n').encode())
                worker.stdin.flush()
                del payload
                challenge = None
            elif event['event'] == 'provisioning_complete':
                try:
                    if worker.wait(timeout=min(20, max(1, deadline - time.time()))) != 0:
                        raise RelayError('worker_failed')
                except subprocess.TimeoutExpired:
                    raise RelayError('worker_failed') from None
                return phase, event
            elif event['event'] == 'agreement_review_required':
                raise RelayError('agreement_review_required')
            else:
                raise RelayError(event['reason'])
    finally:
        if challenge is not None:
            challenge.close()
        stop_worker(worker)
        if (root / STATE_MARKER).exists():
            write_cleanup_state(root, run_id)
        if fd is not None:
            os.close(fd)
        (root / 'apple-credentials.json').unlink(missing_ok=True)


def load_signer():
    spec = importlib.util.spec_from_file_location('bereal_authorized_signer', Path(__file__).with_name('bereal-resign.py'))
    signer = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(signer)
    signer.configure_openssl()
    signer.helper = signer.load_helper()
    return signer


def verify_scoped_profiles(signer, api, der, team, device):
    """Independently validate newly provisioned profiles using GET requests only."""
    results = []
    udid = device['attributes']['udid']
    for identifier in IDENTIFIERS:
        bundles = api.collection('/v1/bundleIds', {'filter[platform]': 'IOS', 'filter[identifier]': identifier})
        matches = [bundle for bundle in bundles if bundle.get('attributes', {}).get('identifier') == identifier
                   and bundle.get('attributes', {}).get('platform') == 'IOS']
        if len(matches) != 1:
            raise RelayError('profiles_verification_failed')
        bundle_id = matches[0].get('id')
        if not isinstance(bundle_id, str) or not re.fullmatch('[A-Za-z0-9_-]{1,100}', bundle_id):
            raise RelayError('profiles_verification_failed')
        candidates = api.collection('/v1/bundleIds/' + bundle_id + '/profiles',
                                   {'fields[profiles]': 'uuid,profileType,profileState,profileContent,expirationDate'})
        selected = None
        for candidate in candidates:
            attributes = candidate.get('attributes', {})
            if attributes.get('profileType') != 'IOS_APP_ADHOC' or attributes.get('profileState') != 'ACTIVE':
                continue
            if not attributes.get('profileContent'):
                profile_id = candidate.get('id')
                if not isinstance(profile_id, str) or not re.fullmatch('[A-Za-z0-9_-]{1,100}', profile_id):
                    raise RelayError('profiles_verification_failed')
                candidate = api.request('GET', '/v1/profiles/' + profile_id)['data']
            try:
                _, profile = signer.validate_profile(candidate, der, team, identifier, udid)
                selected = signer.public_profile_receipt(identifier, profile, der)
                break
            except (RuntimeError, ValueError, TypeError, KeyError):
                continue
        if selected is None:
            raise RelayError('profiles_verification_failed')
        results.append(selected)
    return results


def write_result(public_root, run_id, status, *, reason=None, phase=0, profiles=None,
                 provisioning_event=None):
    receipt = {'version': 1, 'purpose': PURPOSE, 'run_id': run_id, 'status': status,
               'phase': phase, 'credentials_retained': False, 'private_session_retained': False,
               'signed_ipa_created': False}
    if reason is not None:
        receipt['reason'] = reason if reason in FAILURE_REASONS else 'worker_failed'
    if profiles is not None:
        receipt.update(registered_device_count=1, provisioned_bundle_count=5,
                       scoped_provisioning_verified=True, profiles=profiles)
    if provisioning_event is not None:
        validate_control(provisioning_event)
        if provisioning_event['event'] != 'provisioning_complete':
            raise RelayError('worker_protocol_invalid')
        receipt['agreement_status_known'] = provisioning_event['agreement_status_known']
    (public_root / 'result.json').write_text(json.dumps(receipt, indent=2) + '\n')


def main():
    if (os.environ.get('GITHUB_REPOSITORY') != REPOSITORY
            or os.environ.get('GITHUB_REF') != 'refs/heads/main'
            or os.environ.get('GITHUB_ACTIONS') != 'true' or sys.platform != 'darwin'):
        raise RelayError('relay_initialization_failed')
    run_id = os.environ.get('GITHUB_RUN_ID', '')
    validate_run_id(run_id)
    runner_temp = Path(os.environ['RUNNER_TEMP']).resolve(strict=True)
    if not runner_temp.is_dir():
        raise RelayError('relay_initialization_failed')
    if sys.argv[1:] == ['--cleanup-private-state']:
        cleanup_private_state(runner_temp, run_id)
        print('Scoped Apple authentication private-state cleanup finished.', flush=True)
        return 0
    if sys.argv[1:]:
        raise RelayError('relay_initialization_failed')
    os.umask(0o077)
    public_root = Path('bereal-auth-public')
    public_root.mkdir(mode=0o700, exist_ok=True)
    worker_path = Path(__file__).with_suffix('.rb').resolve()
    publisher = Path(__file__).with_name('bereal-auth-publish-challenge.cjs').resolve()
    deadline = time.time() + MAX_DURATION_SECONDS
    challenge, phase, profiles, reason, completion = None, 0, None, None, None

    def cancelled(signum, frame):
        raise RelayError('relay_cancelled')

    old_handlers = {sig: signal.signal(sig, cancelled) for sig in (signal.SIGTERM, signal.SIGINT)}
    try:
        with tempfile.TemporaryDirectory(prefix='bereal-apple-auth-', dir=runner_temp) as directory:
            root = Path(directory)
            write_cleanup_state(root, run_id)
            try:
                signer = load_signer()
                _, der, _, asc = signer.decode_identity(root, need_private_key=False)
                api = signer.RefreshingAppleAPI(asc)
                _, device = signer.signing_readiness(api, der)
                context = {'team_id': os.environ['APPLE_TEAM_ID'],
                           'certificate_sha256': hashlib.sha256(der).hexdigest(),
                           'target_bundle_identifiers': list(IDENTIFIERS),
                           'expected_enabled_device_count': 1}
                challenge = Challenge(root, run_id, 0, int(deadline))
                publish_challenge(challenge, public_root, publisher)
                reader = PublicReplyReader(run_id)
                credentials = wait_reply(challenge, reader, deadline=deadline)
                challenge = None
                try:
                    phase, completion = drive_worker(root, public_root, run_id, credentials, context,
                                                      reader, worker_path, publisher, deadline)
                finally:
                    credentials.clear()
                    del credentials
                profiles = verify_scoped_profiles(signer, api, der, context['team_id'], device)
            finally:
                if challenge is not None:
                    challenge.close()
                # TemporaryDirectory also removes P12, ASC key, context and
                # isolated worker TMPDIR after worker shutdown. The Ruby worker
                # disables Fastlane session/cookie/service-key persistence.
    except RelayError as error:
        reason = error.reason
    except Exception:
        reason = 'relay_initialization_failed'
    finally:
        for sig, handler in old_handlers.items():
            signal.signal(sig, handler)
    # Receipt is written only after private files and worker state are removed.
    write_result(public_root, run_id, 'complete' if reason is None else 'failed',
                 reason=reason, phase=phase, profiles=profiles, provisioning_event=completion)
    if reason is not None:
        print('Apple authentication relay stopped: ' + reason, flush=True)
        return 1
    print('All five scoped Ad Hoc profiles independently verified; private login/session files removed.', flush=True)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception:
        print('Apple authentication relay stopped: relay_initialization_failed', flush=True)
        sys.exit(1)
