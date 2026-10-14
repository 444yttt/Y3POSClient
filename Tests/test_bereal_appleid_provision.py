"""Offline tests for ephemeral credential relay; never contact Apple or GitHub."""
import base64
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import time
import unittest
from unittest import mock

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts' / 'bereal-appleid-provision.py'
SPEC = importlib.util.spec_from_file_location('bereal_appleid_relay', SCRIPT)
relay = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(relay)


def encrypted_reply(challenge, payload, *, context=None, aes_key=None):
    key = aes_key or os.urandom(32)
    iv = os.urandom(12)
    public_key = serialization.load_pem_public_key(challenge.public['public_key_spki_pem'].encode())
    wrapped = public_key.encrypt(key, padding.OAEP(
        mgf=padding.MGF1(hashes.SHA256()), algorithm=hashes.SHA256(), label=None))
    ciphertext = AESGCM(key).encrypt(iv, json.dumps(payload).encode(),
                                     challenge.context if context is None else context)
    result = {field: challenge.public[field] for field in ('version', 'run_id', 'phase', 'nonce', 'expires_at')}
    result.update(wrapped_key=relay.encode(wrapped), iv=relay.encode(iv), ciphertext=relay.encode(ciphertext))
    return result


class RelayCryptoTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.test_key = rsa.generate_private_key(public_exponent=65537, key_size=3072)

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.challenge = relay.Challenge(self.root, '38412345678', 0, 2000,
                                         key=self.test_key, now=1000)

    def tearDown(self):
        self.challenge.close()
        self.directory.cleanup()

    def test_credentials_authenticated_and_private_key_removed_immediately(self):
        self.assertEqual(stat.S_IMODE(self.challenge.key_path.stat().st_mode), 0o600)
        packet = encrypted_reply(self.challenge, {'apple_id': 'person@example.invalid', 'password': 'PRIVATE-TEST'})
        payload = self.challenge.decrypt(packet, now=1001)
        self.assertEqual(payload['password'], 'PRIVATE-TEST')
        self.assertFalse(self.challenge.key_path.exists())
        self.assertIsNone(self.challenge.key)
        with self.assertRaises(ValueError):
            self.challenge.decrypt(packet, now=1002)

    def test_tampered_ciphertext_and_context_rejected(self):
        packet = encrypted_reply(self.challenge, {'apple_id': 'person@example.invalid', 'password': 'secret'})
        ciphertext = bytearray(base64.b64decode(packet['ciphertext']))
        ciphertext[0] ^= 1
        packet['ciphertext'] = relay.encode(ciphertext)
        with self.assertRaises(Exception):
            self.challenge.decrypt(packet, now=1001)
        packet = encrypted_reply(self.challenge, {'apple_id': 'person@example.invalid', 'password': 'secret'}, context=b'other-run')
        with self.assertRaises(Exception):
            self.challenge.decrypt(packet, now=1001)
        self.assertFalse(self.challenge.consumed)

    def test_every_metadata_mismatch_and_type_confusion_rejected(self):
        packet = encrypted_reply(self.challenge, {'apple_id': 'person@example.invalid', 'password': 'secret'})
        alterations = {'version': True, 'run_id': '38412345679', 'phase': 1,
                       'nonce': 'a' * 64, 'expires_at': 2001}
        for field, value in alterations.items():
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.challenge.decrypt({**packet, field: value}, now=1001)
        with self.assertRaises(ValueError):
            self.challenge.decrypt({**packet, 'extra': 'ignored'}, now=1001)

    def test_expired_packet_cannot_decrypt(self):
        packet = encrypted_reply(self.challenge, {'apple_id': 'person@example.invalid', 'password': 'secret'})
        with self.assertRaises(ValueError):
            self.challenge.decrypt(packet, now=2000)

    def test_plaintext_fields_and_size_are_restricted(self):
        invalid = [
            {'apple_id': 'person@example.invalid', 'password': 'secret', 'session': 'unapproved'},
            {'apple_id': '\nperson@example.invalid', 'password': 'secret'},
            {'apple_id': 'person@example.invalid', 'password': ''},
            {'apple_id': 'person@example.invalid', 'password': 'x' * 2049},
            {'apple_id': 'person@example.invalid', 'password': 123},
        ]
        for payload in invalid:
            with self.subTest(payload_shape=list(payload)), self.assertRaises(ValueError):
                self.challenge.decrypt(encrypted_reply(self.challenge, payload), now=1001)

    def test_wrong_aes_key_and_iv_sizes_rejected(self):
        packet = encrypted_reply(self.challenge, {'apple_id': 'person@example.invalid', 'password': 'secret'}, aes_key=os.urandom(16))
        with self.assertRaises(ValueError):
            self.challenge.decrypt(packet, now=1001)
        packet = encrypted_reply(self.challenge, {'apple_id': 'person@example.invalid', 'password': 'secret'})
        packet['iv'] = relay.encode(os.urandom(13))
        with self.assertRaises(ValueError):
            self.challenge.decrypt(packet, now=1001)

    def test_phase_rotates_nonce_and_accepts_only_six_digit_code(self):
        otp = relay.Challenge(self.root, '38412345678', 1, 1500, key=self.test_key, now=1000)
        try:
            self.assertNotEqual(self.challenge.public['nonce'], otp.public['nonce'])
            self.assertEqual(otp.public['allowed_payload'], 'two_factor')
            for code in ('12345', '1234567', '１２３４５６', 123456):
                with self.subTest(code=code), self.assertRaises(ValueError):
                    otp.decrypt(encrypted_reply(otp, {'code': code}), now=1001)
            self.assertEqual(otp.decrypt(encrypted_reply(otp, {'code': '123456'}), now=1001), {'code': '123456'})
        finally:
            otp.close()

    def test_json_duplicate_nonfinite_and_bounds_rejected(self):
        for text in ('{"code":"123456","code":"654321"}', '{"n":NaN}', '{"n":Infinity}'):
            with self.assertRaises(ValueError):
                relay.strict_json(text)
        with self.assertRaises(ValueError):
            relay.strict_json(' ' * (relay.MAX_PACKET_BYTES + 1))

    def test_phase_lifetime_and_run_id_restricted(self):
        for run_id in ('../evil', 'abc', '', '1' * 25):
            with self.assertRaises(relay.RelayError):
                relay.validate_run_id(run_id)
        for phase, expiry in ((True, 1100), (4, 1100), (1, 1601), (0, 3401), (0, 1000)):
            with self.assertRaises(ValueError):
                relay.Challenge(self.root, '1', phase, expiry, key=self.test_key, now=1000)

    def test_poll_skips_stale_or_corrupt_reply_and_decrypts_current(self):
        valid = encrypted_reply(self.challenge, {'apple_id': 'person@example.invalid', 'password': 'secret'})
        stale = {**valid, 'phase': 1}
        reader = mock.Mock()
        reader.fetch.side_effect = [stale, stale, {'garbage': 'public'}, valid]
        clock = mock.Mock(return_value=1001)
        payload = relay.wait_reply(self.challenge, reader, deadline=2000,
                                   sleeper=lambda seconds: None, clock=clock)
        self.assertEqual(payload['password'], 'secret')
        self.assertEqual(reader.fetch.call_count, 4)

    def test_poll_timeout_does_not_leave_decrypted_credential(self):
        reader = mock.Mock()
        reader.fetch.return_value = None
        clock = mock.Mock(side_effect=[1001, 1001, 1001, 2000, 2000])
        with self.assertRaises(relay.RelayError) as raised:
            relay.wait_reply(self.challenge, reader, deadline=2000,
                             sleeper=lambda seconds: None, clock=clock)
        self.assertEqual(raised.exception.reason, 'challenge_timeout')
        self.assertFalse(self.challenge.consumed)

    def test_publisher_output_captured_and_only_safe_receipt_used(self):
        root = self.root / 'public'
        root.mkdir()
        result = subprocess.CompletedProcess([], 0, b'library noise\n{"artifact_id":123,"phase":0}\n', b'private-node-diagnostic')
        with mock.patch.object(relay.subprocess, 'run', return_value=result) as run:
            self.assertEqual(relay.publish_challenge(self.challenge, root, Path('publish.cjs')), 123)
        self.assertTrue(run.call_args.kwargs['capture_output'])
        challenge_text = (root / 'phase-0/challenge.json').read_text()
        self.assertNotIn('PRIVATE KEY', challenge_text)
        self.assertNotIn('password', challenge_text)


class WorkerBoundaryTests(unittest.TestCase):
    def test_fixed_failure_diagnostics_validate_and_reject_raw_values(self):
        event = {'event': 'failure', 'reason': 'authentication_failed',
                 'stage': 'session_validation', 'error_kind': 'unauthorized_access'}
        self.assertEqual(relay.validate_control(event), event)
        for field, value in (('stage', 'private account error'), ('error_kind', 'RuntimeError: password'),
                             ('reason', []), ('stage', []), ('error_kind', True)):
            with self.subTest(field=field, value=value), self.assertRaises(relay.RelayError):
                relay.validate_control({**event, field: value})
        with self.assertRaises(relay.RelayError):
            relay.validate_control({**event, 'message': 'private text'})
        with self.assertRaises(relay.RelayError):
            relay.validate_control({'event': 'failure', 'reason': 'authentication_failed'})

    def test_worker_failure_preserves_last_published_phase_and_safe_diagnostics(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            read_fd, write_fd = os.pipe()
            worker = mock.Mock()
            worker.pid, worker.stdin = 123456, io.BytesIO()
            progress = {'phase': 0}
            control_events = [
                {'event': 'two_factor_required', 'attempt': 1, 'challenge_nonce': 'a' * 64},
                {'event': 'failure', 'reason': 'authentication_failed',
                 'stage': 'two_factor_verification', 'error_kind': 'unauthorized_access'}]
            try:
                with mock.patch.object(relay, 'start_worker', return_value=(worker, read_fd)), \
                     mock.patch.object(relay.ControlReader, 'next', side_effect=control_events), \
                     mock.patch.object(relay, 'publish_challenge', return_value=123), \
                     mock.patch.object(relay, 'wait_reply', return_value={'code': '123456'}), \
                     mock.patch.object(relay, 'stop_worker') as stop:
                    with self.assertRaises(relay.RelayError) as raised:
                        relay.drive_worker(root, root, '123', {'apple_id': 'private', 'password': 'private'},
                                           {}, mock.Mock(), Path('worker.rb'), Path('publisher.cjs'),
                                           time.time() + 20, progress=progress)
                self.assertEqual(progress['phase'], 1)
                self.assertEqual(raised.exception.reason, 'authentication_failed')
                self.assertEqual(raised.exception.auth_stage, 'two_factor_verification')
                self.assertEqual(raised.exception.error_kind, 'unauthorized_access')
                stop.assert_called_once_with(worker)
                self.assertFalse((root / 'apple-credentials.json').exists())
                relay.write_result(root, '123', 'failed', reason=raised.exception.reason,
                                   phase=progress['phase'], auth_stage=raised.exception.auth_stage,
                                   error_kind=raised.exception.error_kind)
                receipt = json.loads((root / 'result.json').read_text())
                self.assertEqual(receipt['phase'], 1)
                self.assertEqual(receipt['auth_stage'], 'two_factor_verification')
                self.assertEqual(receipt['error_kind'], 'unauthorized_access')
                self.assertNotIn('123456', (root / 'result.json').read_text())
            finally:
                os.close(write_fd)

    def test_failure_receipt_omits_unapproved_or_partial_diagnostics(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for stage, kind in (('login', None), ('password error', 'other'), (None, 'other')):
                relay.write_result(root, '123', 'failed', reason='authentication_failed',
                                   auth_stage=stage, error_kind=kind)
                receipt = json.loads((root / 'result.json').read_text())
                self.assertNotIn('auth_stage', receipt)
                self.assertNotIn('error_kind', receipt)
            relay.write_result(root, '123', 'complete', auth_stage='login', error_kind='other')
            receipt = json.loads((root / 'result.json').read_text())
            self.assertNotIn('auth_stage', receipt)
            self.assertNotIn('error_kind', receipt)

    def test_post_cleanup_removes_only_current_run_marked_private_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            current, other, unmarked = (root / name for name in ('bereal-apple-auth-current', 'bereal-apple-auth-other', 'bereal-apple-auth-unmarked'))
            for path in (current, other, unmarked):
                path.mkdir(mode=0o700)
            relay.write_cleanup_state(current, '123')
            relay.write_cleanup_state(other, '456')
            relay.write_private(current / 'private-key.pem', b'TEST PRIVATE KEY')
            (root / 'bereal-apple-auth-symlink').symlink_to(other, target_is_directory=True)
            relay.cleanup_private_state(root, '123')
            self.assertFalse(current.exists())
            self.assertTrue(other.exists())
            self.assertTrue(unmarked.exists())
            self.assertTrue((root / 'bereal-apple-auth-symlink').is_symlink())

    def test_worker_environment_excludes_signing_and_github_secrets(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch.dict(os.environ, {
                'PATH': '/usr/bin', 'BUILD_CERTIFICATE_BASE64': 'SECRET-P12',
                'P12_PASSWORD': 'SECRET-PASSWORD', 'ASC_PRIVATE_KEY': 'SECRET-KEY',
                'GITHUB_TOKEN': 'SECRET-TOKEN', 'BEREAL_CHALLENGE_GITHUB_TOKEN': 'SECRET-PUBLISH-TOKEN',
                'APPLE_TEAM_ID': 'ABCDEFGHIJ',
                'HOME': '/runner-home', 'GITHUB_REPOSITORY': relay.REPOSITORY,
                'GITHUB_REF': 'refs/heads/main'}, clear=True):
            env = relay.worker_environment(Path(directory), 19)
            self.assertEqual(env['BEREAL_CONTROL_FD'], '19')
            self.assertEqual(env['HOME'], '/runner-home')
            self.assertEqual(Path(env['TMPDIR']).parent, Path(directory))
            self.assertFalse(any('SECRET' in value for value in env.values()))
            self.assertNotIn('APPLE_TEAM_ID', env)
            self.assertNotIn('BEREAL_CHALLENGE_GITHUB_TOKEN', env)

    def test_malformed_control_messages_rejected(self):
        invalid = [
            {'event': 'failure', 'reason': 'private server response'},
            {'event': 'agreement_review_required', 'apple_id': 'private'},
            {'event': 'two_factor_required', 'attempt': True, 'challenge_nonce': 'a' * 64},
            {'event': 'two_factor_required', 'attempt': 1, 'challenge_nonce': 'not-a-nonce'},
            {'event': 'provisioning_complete', 'provisioned_bundle_count': 5},
            {'event': 'other'}, [],
        ]
        for event in invalid:
            with self.subTest(event=event), self.assertRaises(relay.RelayError):
                relay.validate_control(event)

    def test_control_reader_rejects_oversized_private_output(self):
        read_fd, write_fd = os.pipe()
        try:
            os.write(write_fd, b'x' * 9000)
            with self.assertRaises(relay.RelayError) as raised:
                relay.ControlReader(read_fd).next(mock.Mock(), time.time() + 5)
            self.assertEqual(raised.exception.reason, 'worker_protocol_invalid')
        finally:
            os.close(read_fd)
            os.close(write_fd)

    @unittest.skipUnless(__import__('shutil').which('ruby'), 'Ruby is required only for isolated fake-worker test')
    def test_fake_worker_cleanup_after_malformed_control_event(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            worker_path = root / 'fake-worker.rb'
            worker_path.write_text('''require 'json'
File.unlink(ARGV[0])
File.write(File.join(ENV.fetch('TMPDIR'), 'private-cookie'), 'test-session')
fd = IO.new(Integer(ENV.fetch('BEREAL_CONTROL_FD')), 'w')
fd.write(JSON.generate({event: 'failure', reason: 'unsafe account text'}) + "\\n")
fd.flush
sleep 30
''')
            with self.assertRaises(relay.RelayError) as raised:
                relay.drive_worker(root, root, '123', {'apple_id': 'private', 'password': 'private'},
                                   {}, mock.Mock(), worker_path, Path('unused'), time.time() + 10)
            self.assertEqual(raised.exception.reason, 'worker_protocol_invalid')
            self.assertFalse((root / 'apple-credentials.json').exists())
            # Main's enclosing TemporaryDirectory removes all remaining context
            # and private worker temp paths after drive_worker stops the child.
            session = root / 'worker-temp/private-cookie'
            self.assertTrue(session.exists())
        self.assertFalse(session.exists())

    def test_public_receipt_contains_no_worker_or_account_details(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            relay.write_result(root, '123', 'failed', reason='private password error')
            receipt = json.loads((root / 'result.json').read_text())
            self.assertEqual(receipt['reason'], 'worker_failed')
            self.assertFalse(receipt['credentials_retained'])
            self.assertFalse(receipt['private_session_retained'])
            self.assertNotIn('password', receipt)


class ReadOnlyValidationTests(unittest.TestCase):
    def test_all_five_profiles_independently_validate_with_get_only(self):
        api = mock.Mock()
        signer = mock.Mock()
        def collection(path, filters):
            if path == '/v1/bundleIds':
                return [{'id': 'BUNDLE1', 'attributes': {'identifier': filters['filter[identifier]'], 'platform': 'IOS'}}]
            return [{'id': 'PROFILE1', 'attributes': {'profileType': 'IOS_APP_ADHOC', 'profileState': 'ACTIVE'}}]
        api.collection.side_effect = collection
        api.request.return_value = {'data': {'id': 'PROFILE1', 'attributes': {'profileContent': 'opaque'}}}
        signer.validate_profile.return_value = (b'validated-CMS', {'validated': True})
        signer.public_profile_receipt.side_effect = lambda identifier, profile, der: {'bundle_identifier': identifier}
        results = relay.verify_scoped_profiles(signer, api, b'current-certificate', 'ABCDEFGHIJ', {'attributes': {'udid': 'PRIVATE-DEVICE'}})
        self.assertEqual({item['bundle_identifier'] for item in results}, set(relay.IDENTIFIERS))
        self.assertEqual(signer.validate_profile.call_count, 5)
        self.assertTrue(all(call.args[0] == 'GET' for call in api.request.call_args_list))
        signer.get_profile.assert_not_called()

    def test_ios_and_universal_exact_registration_with_wide_results_keep_get_only_validation(self):
        for platform in ('IOS', 'UNIVERSAL'):
            with self.subTest(platform=platform):
                api, signer = mock.Mock(), mock.Mock()
                def collection(path, filters):
                    if path == '/v1/bundleIds':
                        self.assertEqual(set(filters), {'filter[identifier]'})
                        identifier = filters['filter[identifier]']
                        return [
                            {'id': 'PREFIX', 'attributes': {'identifier': identifier + '.preview', 'platform': 'MAC_OS'}},
                            {'id': 'UNRELATED', 'attributes': {'identifier': 'com.other.app', 'platform': 'UNKNOWN'}},
                            {'id': 'SCOPED', 'attributes': {'identifier': identifier, 'platform': platform}},
                        ]
                    self.assertEqual(path, '/v1/bundleIds/SCOPED/profiles')
                    return [{'id': 'PROFILE1', 'attributes': {
                        'profileType': 'IOS_APP_ADHOC', 'profileState': 'ACTIVE', 'profileContent': 'opaque-CMS'}}]
                api.collection.side_effect = collection
                signer.validate_profile.return_value = (b'verified-CMS', {'validated': True})
                signer.public_profile_receipt.side_effect = lambda identifier, profile, der: {'bundle_identifier': identifier}
                results = relay.verify_scoped_profiles(
                    signer, api, b'approved-certificate', 'ABCDEFGHIJ', {'attributes': {'udid': 'PRIVATE-DEVICE'}})
                self.assertEqual({item['bundle_identifier'] for item in results}, set(relay.IDENTIFIERS))
                self.assertEqual([call.args[3] for call in signer.validate_profile.call_args_list], list(relay.IDENTIFIERS))
                self.assertTrue(all(call.args[1:3] == (b'approved-certificate', 'ABCDEFGHIJ')
                                    and call.args[4] == 'PRIVATE-DEVICE'
                                    for call in signer.validate_profile.call_args_list))
                api.request.assert_not_called()
                signer.get_profile.assert_not_called()

    def test_exact_wrong_platform_or_ambiguous_registration_rejects_before_profile_reads(self):
        for platforms in (['MAC_OS'], ['UNKNOWN'], [None], [''], ['IOS', 'UNIVERSAL'],
                          ['UNIVERSAL', 'UNIVERSAL'], ['IOS', 'MAC_OS']):
            with self.subTest(platforms=platforms):
                api, signer = mock.Mock(), mock.Mock()
                resources = [{'id': 'PREFIX', 'attributes': {
                    'identifier': relay.ROOT_ID + '.preview', 'platform': 'UNIVERSAL'}}]
                resources.extend({'id': 'BUNDLE' + str(index), 'attributes': {
                    'identifier': relay.ROOT_ID, 'platform': platform}} for index, platform in enumerate(platforms))
                api.collection.return_value = resources
                with self.assertRaises(relay.RelayError) as raised:
                    relay.verify_scoped_profiles(signer, api, b'certificate', 'ABCDEFGHIJ', {'attributes': {'udid': 'private'}})
                self.assertEqual(raised.exception.reason, 'profiles_verification_failed')
                api.collection.assert_called_once_with('/v1/bundleIds', {'filter[identifier]': relay.ROOT_ID})
                api.request.assert_not_called()
                signer.validate_profile.assert_not_called()
                signer.get_profile.assert_not_called()

    def test_wide_prefix_only_registration_is_not_an_exact_match(self):
        api, signer = mock.Mock(), mock.Mock()
        api.collection.return_value = [{'id': 'PREFIX', 'attributes': {
            'identifier': relay.ROOT_ID + '.preview', 'platform': 'UNIVERSAL'}}]
        with self.assertRaises(relay.RelayError):
            relay.verify_scoped_profiles(signer, api, b'certificate', 'ABCDEFGHIJ', {'attributes': {'udid': 'private'}})
        signer.validate_profile.assert_not_called()
        api.request.assert_not_called()
        signer.get_profile.assert_not_called()

    def test_universal_metadata_cannot_bypass_profile_distribution_or_strict_validation(self):
        for distribution in ('IOS_APP_ADHOC', 'IOS_APP_STORE', 'MAC_APP_DIRECT'):
            with self.subTest(distribution=distribution):
                api, signer = mock.Mock(), mock.Mock()
                api.collection.side_effect = [
                    [{'id': 'BUNDLE1', 'attributes': {'identifier': relay.ROOT_ID, 'platform': 'UNIVERSAL'}}],
                    [{'id': 'PROFILE1', 'attributes': {
                        'profileType': distribution, 'profileState': 'ACTIVE', 'profileContent': 'invalid-CMS'}}],
                ]
                signer.validate_profile.side_effect = RuntimeError('strict certificate/team/device/CMS rejection')
                with self.assertRaises(relay.RelayError) as raised:
                    relay.verify_scoped_profiles(signer, api, b'certificate', 'ABCDEFGHIJ', {'attributes': {'udid': 'private'}})
                self.assertEqual(raised.exception.reason, 'profiles_verification_failed')
                self.assertEqual(signer.validate_profile.call_count, 1 if distribution == 'IOS_APP_ADHOC' else 0)
                api.request.assert_not_called()
                signer.get_profile.assert_not_called()

    def test_invalid_profiles_never_fall_back_to_creation(self):
        api, signer = mock.Mock(), mock.Mock()
        api.collection.side_effect = [
            [{'id': 'BUNDLE1', 'attributes': {'identifier': relay.ROOT_ID, 'platform': 'IOS'}}],
            [{'id': 'PROFILE1', 'attributes': {'profileType': 'IOS_APP_ADHOC', 'profileState': 'ACTIVE', 'profileContent': 'opaque'}}],
        ]
        signer.validate_profile.side_effect = RuntimeError('invalid private profile')
        with self.assertRaises(relay.RelayError) as raised:
            relay.verify_scoped_profiles(signer, api, b'certificate', 'ABCDEFGHIJ', {'attributes': {'udid': 'private'}})
        self.assertEqual(raised.exception.reason, 'profiles_verification_failed')
        api.request.assert_not_called()
        signer.get_profile.assert_not_called()


class EncryptedSMSTargetTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        cls.certificate_der = b'only-public-test-certificate-DER'
        cls.phone = '+819012345678'

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.key_path = relay.write_private(self.root / 'signing-private.pem', self.key.private_bytes(
            serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
        self.path = self.root / 'bereal-auth-sms-target.json'

    def tearDown(self):
        self.directory.cleanup()

    def config(self, phone=None, key=None):
        ciphertext = (key or self.key).public_key().encrypt(
            (self.phone if phone is None else phone).encode('utf-8'), padding.OAEP(
                mgf=padding.MGF1(hashes.SHA256()), algorithm=hashes.SHA256(), label=None))
        return {'version': 1, 'algorithm': 'RSA-OAEP-SHA256',
                'certificate_sha256': __import__('hashlib').sha256(self.certificate_der).hexdigest(),
                'ciphertext': relay.encode(ciphertext)}

    def write_config(self, config):
        self.path.write_text(json.dumps(config))

    def test_valid_encrypted_phone_remains_private_and_cleanup_removes_key(self):
        self.write_config(self.config())
        self.assertNotIn(self.phone, self.path.read_text())
        self.assertEqual(relay.decrypt_sms_target(self.path, self.certificate_der, self.key_path), self.phone)
        relay.write_result(self.root, '123', 'failed', reason='authentication_failed')
        self.assertNotIn(self.phone, (self.root / 'result.json').read_text())
        self.assertNotIn('sms_phone_number', (self.root / 'result.json').read_text())
        # The same enclosing private TemporaryDirectory owns the decoded P12
        # key, private worker context and SMS target during the actual relay.
        private_key_path = self.key_path
        self.directory.cleanup()
        self.assertFalse(private_key_path.exists())

    def test_wrong_certificate_algorithm_schema_or_version_rejected_safely(self):
        original = self.config()
        changes = [
            {'certificate_sha256': '0' * 64}, {'algorithm': 'RSA-OAEP-SHA1'},
            {'version': True}, {'version': 2}, {'phone': self.phone},
        ]
        for change in changes:
            with self.subTest(field=next(iter(change))):
                self.write_config({**original, **change})
                with self.assertRaises(relay.RelayError) as raised:
                    relay.decrypt_sms_target(self.path, self.certificate_der, self.key_path)
                self.assertEqual(str(raised.exception), 'invalid_context')
                self.assertNotIn(self.phone, str(raised.exception))
        self.write_config({key: value for key, value in original.items() if key != 'algorithm'})
        with self.assertRaises(relay.RelayError):
            relay.decrypt_sms_target(self.path, self.certificate_der, self.key_path)

    def test_corrupt_ciphertext_wrong_key_and_invalid_phone_rejected(self):
        original = self.config()
        ciphertext = bytearray(base64.b64decode(original['ciphertext']))
        ciphertext[0] ^= 1
        invalid = [{**original, 'ciphertext': relay.encode(ciphertext)},
                   {**original, 'ciphertext': relay.encode(b'too short')},
                   self.config(key=rsa.generate_private_key(public_exponent=65537, key_size=2048))]
        invalid += [self.config(phone=phone) for phone in (
            '819012345678', '+019012345678', '+1234567', '+1234567890123456',
            '+819012345678\n', '+81 9012345678', '＋819012345678')]
        for config in invalid:
            self.write_config(config)
            with self.assertRaises(relay.RelayError) as raised:
                relay.decrypt_sms_target(self.path, self.certificate_der, self.key_path)
            self.assertEqual(str(raised.exception), 'invalid_context')

    def test_duplicate_oversized_and_symlink_configuration_rejected(self):
        self.path.write_text('{"version":1,"version":1}')
        with self.assertRaises(relay.RelayError):
            relay.decrypt_sms_target(self.path, self.certificate_der, self.key_path)
        self.path.write_text(' ' * 8193)
        with self.assertRaises(relay.RelayError):
            relay.decrypt_sms_target(self.path, self.certificate_der, self.key_path)
        self.path.unlink()
        self.path.symlink_to(self.key_path)
        with self.assertRaises(relay.RelayError):
            relay.decrypt_sms_target(self.path, self.certificate_der, self.key_path)

    def test_runner_sms_present_or_absent_context_and_private_key_cleanup(self):
        completion = {'event': 'provisioning_complete', 'created_bundle_count': 5, 'reused_bundle_count': 0,
                      'created_profile_count': 5, 'reused_profile_count': 0,
                      'registered_device_count': 1, 'provisioned_bundle_count': 5,
                      'agreement_status_known': True}
        for sms_present in (False, True):
            with self.subTest(sms_present=sms_present), tempfile.TemporaryDirectory() as directory:
                workspace = Path(directory)
                runner_temp = workspace / 'runner-temp'
                runner_temp.mkdir()
                if sms_present:
                    (workspace / 'bereal-auth-sms-target.json').write_text(json.dumps(self.config()))
                signer, seen = mock.Mock(), {}
                def decode_identity(root, need_private_key):
                    seen['root'] = root
                    key_path = root / 'signing-private.pem'
                    if need_private_key:
                        relay.write_private(key_path, self.key_path.read_bytes())
                    return root / 'identity.p12', self.certificate_der, key_path if need_private_key else None, root / 'AuthKey.p8'
                signer.decode_identity.side_effect = decode_identity
                signer.signing_readiness.return_value = ({}, {'attributes': {'udid': 'PRIVATE-DEVICE'}})
                def private_worker(root, public_root, run_id, credentials, context, *args, **kwargs):
                    self.assertEqual(context.get('sms_phone_number'), self.phone if sms_present else None)
                    self.assertFalse((root / 'signing-private.pem').exists())
                    relay.write_private(root / 'apple-context.json', json.dumps(context).encode())
                    return 1, completion
                env = {'GITHUB_REPOSITORY': relay.REPOSITORY, 'GITHUB_REF': 'refs/heads/main',
                       'GITHUB_ACTIONS': 'true', 'GITHUB_RUN_ID': '123',
                       'RUNNER_TEMP': str(runner_temp), 'APPLE_TEAM_ID': 'ABCDEFGHIJ'}
                output = io.StringIO()
                with mock.patch.dict(os.environ, env), mock.patch.object(relay.sys, 'platform', 'darwin'), \
                     mock.patch.object(relay.sys, 'argv', ['bereal-appleid-provision.py']), \
                     mock.patch.object(relay, 'load_signer', return_value=signer), \
                     mock.patch.object(relay, 'Challenge'), mock.patch.object(relay, 'publish_challenge'), \
                     mock.patch.object(relay, 'wait_reply', return_value={'apple_id': 'private', 'password': 'private'}), \
                     mock.patch.object(relay, 'drive_worker', side_effect=private_worker), \
                     mock.patch.object(relay, 'verify_scoped_profiles', return_value=[]), \
                     contextlib.chdir(workspace), contextlib.redirect_stdout(output):
                    self.assertEqual(relay.main(), 0)
                self.assertEqual(signer.decode_identity.call_args.kwargs['need_private_key'], sms_present)
                self.assertFalse(seen['root'].exists())
                receipt = (workspace / 'bereal-auth-public/result.json').read_text()
                self.assertNotIn(self.phone, receipt + output.getvalue())
                self.assertNotIn('sms_phone_number', receipt)


if __name__ == '__main__':
    unittest.main()
