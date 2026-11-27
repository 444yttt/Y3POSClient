import datetime as dt
import hashlib
import importlib.util
from pathlib import Path
import plistlib
import shutil
import ssl
import struct
import subprocess
import sys
import tempfile
import unittest


MODULE_PATH = Path(__file__).resolve().parents[1] / 'scripts' / 'verify_signed_ipa.py'
spec = importlib.util.spec_from_file_location('bump_independent_verifier', MODULE_PATH)
verify = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = verify
spec.loader.exec_module(verify)


def blob(magic, value):
    return struct.pack('>II', magic, 8 + len(value)) + value


def directory(code, slots, external=None, identifier='com.ayato.bumpdebug', team='ABCDE12345', alternate=False):
    external = external or {}
    # Primary SHA256 and alternate SHA256-truncated-to-20 are both exercised.
    hash_size = 20 if alternate else 32
    hash_type = 3 if alternate else 2
    ident = identifier.encode() + b'\0'
    team_bytes = team.encode() + b'\0'
    special_count = 7
    hash_offset = 52 + len(ident) + len(team_bytes) + special_count * hash_size
    length = hash_offset + hash_size
    header = struct.pack('>9I4B3I', 0xFADE0C02, length, 0x20200, 0, hash_offset, 52,
                         special_count, 1, len(code), hash_size, hash_type, 0, 12, 0, 0, 52 + len(ident))
    hashes = []
    for slot in range(special_count, 0, -1):
        value = {**slots, **external}.get(slot)
        hashes.append(hashlib.sha256(value).digest()[:hash_size] if value is not None else b'\0' * hash_size)
    return header + ident + team_bytes + b''.join(hashes) + hashlib.sha256(code).digest()[:hash_size]


@unittest.skipUnless(shutil.which('openssl'), 'OpenSSL is required for cryptographic verifier tests')
class CryptographicTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.temp.name)
        cls.key = cls.root / 'test-only.key'
        cls.cert = cls.root / 'test-only.pem'
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                        '-keyout', str(cls.key), '-out', str(cls.cert), '-days', '1',
                        '-subj', '/CN=Apple Distribution Test/OU=ABCDE12345'],
                       capture_output=True, check=True)
        cls.der = ssl.PEM_cert_to_DER_cert(cls.cert.read_text())

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def sign(self, value, detached=True):
        arguments = ['openssl', 'cms', '-sign', '-binary', '-signer', str(self.cert),
                     '-inkey', str(self.key), '-outform', 'DER']
        if not detached:
            arguments.append('-nodetach')
        return subprocess.run(arguments, input=value, capture_output=True, check=True).stdout

    def signed_macho(self, external=None):
        data = bytearray(4096)
        data[:32] = struct.pack('<8I', 0xFEEDFACF, 0x100000C, 0, 2, 1, 16, 0, 0)
        data[32:48] = struct.pack('<4I', 0x1D, 16, 4096, 4096)
        data[128:160] = bytes(range(32))
        entitlements = {'application-identifier': 'ABCDE12345.com.ayato.bumpdebug',
                        'com.apple.developer.team-identifier': 'ABCDE12345',
                        'get-task-allow': False,
                        'keychain-access-groups': ['ABCDE12345.com.ayato.bumpdebug']}
        slots = {5: blob(0xFADE7171, plistlib.dumps(entitlements)),
                 7: blob(0xFADE7172, b'synthetic-DER-binding-test')}
        primary = directory(bytes(data), slots, external)
        slots[0] = primary
        slots[0x1000] = directory(bytes(data), slots, external, alternate=True)
        slots[0x10000] = blob(0xFADE0B01, self.sign(primary))
        header_size = 12 + 8 * len(slots)
        offsets, content = [], bytearray()
        for slot, value in sorted(slots.items()):
            offsets.append(struct.pack('>II', slot, header_size + len(content)))
            content.extend(value)
        signature = struct.pack('>III', 0xFADE0CC0, header_size + len(content), len(slots)) + b''.join(offsets) + content
        self.assertLess(len(signature), 4096)
        data.extend(signature)
        data.extend(b'\0' * (8192 - len(data)))
        return bytes(data), entitlements

    def run_verify(self, data, expected=None, external=None):
        return verify.verify_macho(data, self.root, {}, dt.datetime.now(dt.timezone.utc),
                                   expected=expected, external_slots=external)

    def test_valid_primary_and_alternate_pages_cms_special_slots_and_signer(self):
        external = {1: b'Info.plist content', 3: b'CodeResources content'}
        data, entitlements = self.signed_macho(external)
        records = self.run_verify(data,
                                  expected={'identifier': 'com.ayato.bumpdebug', 'entitlements': entitlements,
                                            'certificate_fingerprints': {hashlib.sha256(self.der).hexdigest()}},
                                  external=external)
        self.assertEqual(len(records), 1)
        self.assertTrue(records[0]['der_entitlements_present'])
        self.assertEqual(records[0]['xml_entitlements'], entitlements)

    def test_code_page_tampering_rejected(self):
        data, _ = self.signed_macho()
        changed = bytearray(data); changed[128] ^= 1
        with self.assertRaisesRegex(verify.VerificationError, 'code-page hash mismatch'):
            self.run_verify(bytes(changed))

    def test_resource_special_slot_tampering_and_missing_binding_rejected(self):
        data, _ = self.signed_macho({1: b'Info', 3: b'Resources'})
        with self.assertRaisesRegex(verify.VerificationError, 'resource hash mismatch'):
            self.run_verify(data, external={1: b'changed', 3: b'Resources'})
        with self.assertRaisesRegex(verify.VerificationError, 'special slot without corresponding data'):
            self.run_verify(data)

    def test_signature_tampering_rejected_by_openssl(self):
        data, _ = self.signed_macho()
        changed = bytearray(data)
        slots = verify.superblob(data[4096:])
        signature = slots[0x10000]
        at = data.index(signature, 4096)
        changed[at + len(signature) - 1] ^= 1
        with self.assertRaisesRegex(verify.VerificationError, 'OpenSSL validation failed'):
            self.run_verify(bytes(changed))

    def test_profile_cms_signature_and_content(self):
        value = plistlib.dumps({'Entitlements': {'get-task-allow': False}})
        signed = self.sign(value, detached=False)
        actual = verify.run_openssl(['cms', '-verify', '-binary', '-inform', 'DER', '-noverify'], signed)
        self.assertEqual(plistlib.loads(actual), plistlib.loads(value))
        changed = bytearray(signed); changed[-1] ^= 1
        with self.assertRaises(verify.VerificationError):
            verify.run_openssl(['cms', '-verify', '-binary', '-inform', 'DER', '-noverify'], bytes(changed))

    def test_signer_must_be_granted_by_profile(self):
        data, entitlements = self.signed_macho()
        with self.assertRaisesRegex(verify.VerificationError, 'not granted by profile'):
            self.run_verify(data, expected={'identifier': 'com.ayato.bumpdebug', 'entitlements': entitlements,
                                            'certificate_fingerprints': {'not-a-certificate'}})

    def test_entitlements_must_match_concrete_grants(self):
        data, entitlements = self.signed_macho()
        wrong = dict(entitlements); wrong['get-task-allow'] = True
        with self.assertRaisesRegex(verify.VerificationError, 'differ from concrete profile'):
            self.run_verify(data, expected={'identifier': 'com.ayato.bumpdebug', 'entitlements': wrong,
                                            'certificate_fingerprints': {hashlib.sha256(self.der).hexdigest()}})


class StructureTests(unittest.TestCase):
    def test_main_provenance_allows_only_injection_and_signature_sizing(self):
        signature_offset = 151552
        original = bytearray(signature_offset + 4096)
        segment = struct.pack('<II16s4Q4I', 0x19, 72, b'__LINKEDIT', 0, 8192,
                              147456, 8192, 7, 1, 0, 0)
        signature = struct.pack('<4I', 0x1D, 16, signature_offset, 4096)
        old_commands = segment + signature
        original[:32] = struct.pack('<8I', 0xFEEDFACF, 0x100000C, 0, 2, 2, len(old_commands), 0, 0)
        original[32:32 + len(old_commands)] = old_commands
        original[147456:signature_offset] = b'P' * (signature_offset - 147456)
        signed = bytearray(original)
        name = verify.ADAPTER.encode() + b'\0'
        size = (24 + len(name) + 7) & ~7
        injected = struct.pack('<6I', 0xC, size, 24, 0, 0, 0) + name + b'\0' * (size - 24 - len(name))
        new_commands = bytearray(segment + injected + signature)
        struct.pack_into('<Q', new_commands, 32, 12288)
        struct.pack_into('<Q', new_commands, 48, 12288)
        struct.pack_into('<II', signed, 16, 3, len(new_commands))
        signed[32:32 + len(new_commands)] = new_commands
        signed[signature_offset:] = b'S' * 4096
        result = verify._verify_main_provenance(bytes(original), bytes(signed))
        self.assertTrue(result['original_main_code_and_data_unchanged'])
        bad = bytearray(signed); bad[147460] ^= 1
        with self.assertRaisesRegex(verify.VerificationError, 'code or data changed'):
            verify._verify_main_provenance(bytes(original), bytes(bad))
        bad = bytearray(signed); bad[32 + 24] ^= 1  # __LINKEDIT vmaddr is not a signing size
        with self.assertRaisesRegex(verify.VerificationError, 'load-command mutation'):
            verify._verify_main_provenance(bytes(original), bytes(bad))

    def test_wildcard_profile_is_concretized_without_original_identity(self):
        profile = {'ApplicationIdentifierPrefix': ['ABCDE12345'], 'TeamIdentifier': ['ABCDE12345'],
                   'Entitlements': {'application-identifier': 'ABCDE12345.*',
                                    'com.apple.developer.team-identifier': 'ABCDE12345',
                                    'get-task-allow': False,
                                    'keychain-access-groups': ['ABCDE12345.*', 'com.apple.token']}}
        actual = verify.concrete_entitlements(profile, 'com.ayato.bumpdebug.lpse')
        self.assertEqual(actual['application-identifier'], 'ABCDE12345.com.ayato.bumpdebug.lpse')
        self.assertEqual(actual['keychain-access-groups'], ['ABCDE12345.com.ayato.bumpdebug.lpse',
                                                          'ABCDE12345.com.ayato.bumpdebug'])
        self.assertEqual(verify.selected_keychain_group(actual), 'ABCDE12345.com.ayato.bumpdebug')
        with self.assertRaises(verify.VerificationError):
            verify.concrete_entitlements(profile, 'co.amo.ios.location')

    def test_exact_profile_without_common_grant_selects_only_own_keychain(self):
        profile = {'ApplicationIdentifierPrefix': ['ABCDE12345'], 'TeamIdentifier': ['ABCDE12345'],
                   'Entitlements': {'application-identifier': 'ABCDE12345.com.ayato.bumpdebug.lpse',
                                    'com.apple.developer.team-identifier': 'ABCDE12345', 'get-task-allow': False,
                                    'keychain-access-groups': ['ABCDE12345.com.ayato.bumpdebug.lpse',
                                                             'ABCDE12345.unused.other-app', 'com.apple.token']}}
        actual = verify.concrete_entitlements(profile, 'com.ayato.bumpdebug.lpse')
        self.assertEqual(actual['keychain-access-groups'], ['ABCDE12345.com.ayato.bumpdebug.lpse'])
        self.assertEqual(verify.selected_keychain_group(actual), 'ABCDE12345.com.ayato.bumpdebug.lpse')
        actual['keychain-access-groups'].append('ABCDE12345.*')
        with self.assertRaisesRegex(verify.VerificationError, 'broad or duplicate'):
            verify.selected_keychain_group(actual)

    def test_profile_without_own_grant_cannot_claim_common_only(self):
        profile = {'ApplicationIdentifierPrefix': ['ABCDE12345'], 'TeamIdentifier': ['ABCDE12345'],
                   'Entitlements': {'application-identifier': 'ABCDE12345.com.ayato.bumpdebug.lpse',
                                    'com.apple.developer.team-identifier': 'ABCDE12345', 'get-task-allow': False,
                                    'keychain-access-groups': ['ABCDE12345.com.ayato.bumpdebug']}}
        with self.assertRaisesRegex(verify.VerificationError, 'no scoped app keychain grant'):
            verify.concrete_entitlements(profile, 'com.ayato.bumpdebug.lpse')

    def test_signature_blob_overlap_rejected(self):
        data = struct.pack('>III4I', 0xFADE0CC0, 40, 2, 0, 28, 0x10000, 28) + struct.pack('>II', 0xFADE0C02, 12) + b'abcd'
        with self.assertRaisesRegex(verify.VerificationError, 'Overlapping'):
            verify.superblob(data)


if __name__ == '__main__':
    unittest.main()
