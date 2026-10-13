"""Offline tests for ephemeral credential relay; never contact Apple or GitHub."""
import base64
import importlib.util
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
                'GITHUB_TOKEN': 'SECRET-TOKEN', 'APPLE_TEAM_ID': 'ABCDEFGHIJ',
                'HOME': '/runner-home', 'GITHUB_REPOSITORY': relay.REPOSITORY,
                'GITHUB_REF': 'refs/heads/main'}, clear=True):
            env = relay.worker_environment(Path(directory), 19)
            self.assertEqual(env['BEREAL_CONTROL_FD'], '19')
            self.assertEqual(env['HOME'], '/runner-home')
            self.assertEqual(Path(env['TMPDIR']).parent, Path(directory))
            self.assertFalse(any('SECRET' in value for value in env.values()))
            self.assertNotIn('APPLE_TEAM_ID', env)

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


if __name__ == '__main__':
    unittest.main()
