"""Authenticated input and nine-bundle signing boundaries, without Apple access."""
import base64
import copy
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import struct
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "ci/bump-resign.py"
if not SOURCE.is_file():
    SOURCE = ROOT.parent / "scripts/bump-resign.py"
SPEC = importlib.util.spec_from_file_location("bump_signer_tests", SOURCE)
SIGNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SIGNER)


class EnvelopeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        cls.pem = cls.key.private_bytes(serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8, serialization.NoEncryption())

    def envelope(self, payload=None):
        payload = payload or {"url": "https://cvws.icloud-content.com/file?token=private-marker",
            "allowed_hosts": ["cvws.icloud-content.com"], "input_sha256": SIGNER.INPUT_SHA256}
        key, nonce = os.urandom(32), os.urandom(12)
        wrapped = self.key.public_key().encrypt(key, padding.OAEP(mgf=padding.MGF1(hashes.SHA256()), algorithm=hashes.SHA256(), label=None))
        return {"version": 1, "input_sha256": SIGNER.INPUT_SHA256,
            "wrapped_key": base64.b64encode(wrapped).decode(), "nonce": base64.b64encode(nonce).decode(),
            "ciphertext": base64.b64encode(AESGCM(key).encrypt(nonce, json.dumps(payload).encode(), SIGNER.AAD)).decode()}

    def test_authenticated_roundtrip_and_secret_safe_failures(self):
        envelope = self.envelope()
        payload = SIGNER.decrypt_envelope(envelope, self.pem)
        self.assertEqual(payload["allowed_hosts"], ["cvws.icloud-content.com"])
        self.assertIn("private-marker", payload["url"])
        for field in ("wrapped_key", "nonce", "ciphertext"):
            altered = copy.deepcopy(envelope)
            raw = bytearray(base64.b64decode(altered[field]))
            raw[-1] ^= 1
            altered[field] = base64.b64encode(raw).decode()
            with self.subTest(field=field), self.assertRaises(SIGNER.BumpError) as error:
                SIGNER.decrypt_envelope(altered, self.pem)
            self.assertNotIn("private-marker", str(error.exception))

    def test_foreign_key_and_wrong_aad_rejected(self):
        envelope = self.envelope()
        other = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        pem = other.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
        with self.assertRaisesRegex(SIGNER.BumpError, "authentication_failed"):
            SIGNER.decrypt_envelope(envelope, pem)
        old_aad = SIGNER.AAD
        try:
            SIGNER.AAD = b"wrong-context"
            with self.assertRaisesRegex(SIGNER.BumpError, "authentication_failed"):
                SIGNER.decrypt_envelope(envelope, self.pem)
        finally:
            SIGNER.AAD = old_aad

    def test_manifest_version_and_input_identity_cannot_change(self):
        for patch in ({"version": True}, {"version": 2}, {"input_sha256": "0" * 64}, {"extra": 1}, {"nonce": "@@"}):
            envelope = self.envelope()
            envelope.update(patch)
            with self.subTest(patch=patch), self.assertRaises(SIGNER.BumpError):
                SIGNER.decrypt_envelope(envelope, self.pem)

    def test_plaintext_url_is_bound_to_exact_icloud_host(self):
        baseline = {"url": "https://cvws.icloud-content.com/file?token=private-marker",
            "allowed_hosts": ["cvws.icloud-content.com"], "input_sha256": SIGNER.INPUT_SHA256}
        variants = [
            {"url": "http://cvws.icloud-content.com/file"},
            {"url": "https://cvws.icloud-content.com.evil.test/file"},
            {"url": "https://user:pass@cvws.icloud-content.com/file"},
            {"url": "https://cvws.icloud-content.com:444/file"},
            {"url": "https://cvws.icloud-content.com/file#fragment"},
            {"url": "https://cvws.icloud-content.com/file\nfoo"},
            {"allowed_hosts": ["*.icloud-content.com"]},
            {"allowed_hosts": ["icloud-content.com"]},
            {"allowed_hosts": ["cvws.icloud-content.com", "other.icloud-content.com"]},
            {"allowed_hosts": ["other.icloud-content.com"]},
            {"input_sha256": "foreign"},
            {"extra": "value"},
        ]
        for patch in variants:
            payload = {**baseline, **patch}
            with self.subTest(patch=patch), self.assertRaises(SIGNER.BumpError) as error:
                SIGNER.decrypt_envelope(self.envelope(payload), self.pem)
            self.assertNotIn("private-marker", str(error.exception))


class BundleTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.app = Path(self.temporary.name) / "Location.app"
        self.bundles = []
        for index, suffix in enumerate(SIGNER.SUFFIXES):
            bundle = self.app if not suffix else self.app / "PlugIns" / f"Test{index}.appex"
            bundle.mkdir(parents=True)
            info = {"CFBundleIdentifier": SIGNER.ORIGINAL_ID + suffix, "CFBundleExecutable": "Executable",
                "CFBundleShortVersionString": "2.135.0", "CFBundleVersion": "261126153935"}
            (bundle / "Info.plist").write_bytes(plistlib.dumps(info))
            (bundle / "Executable").write_bytes(b"test fixture")
            self.bundles.append(bundle)

    def change(self, bundle, key, value):
        path = bundle / "Info.plist"
        info = plistlib.loads(path.read_bytes())
        info[key] = value
        path.write_bytes(plistlib.dumps(info))

    def test_all_nine_exact_identities_mapped(self):
        targets = SIGNER.validate_bundles(self.app)
        self.assertEqual({identifier for _, _, identifier in targets}, {SIGNER.ROOT_ID + suffix for suffix in SIGNER.SUFFIXES})
        self.assertEqual(len(targets), 9)

    def test_foreign_duplicate_missing_and_wrong_version_rejected(self):
        changes = [(self.bundles[1], "CFBundleIdentifier", "co.unrelated.app"),
            (self.bundles[1], "CFBundleIdentifier", SIGNER.ORIGINAL_ID),
            (self.app, "CFBundleVersion", "different"),
            (self.app, "CFBundleExecutable", "../escape")]
        for bundle, key, value in changes:
            path = bundle / "Info.plist"
            original = path.read_bytes()
            self.change(bundle, key, value)
            with self.subTest(key=key, value=value), self.assertRaises(SIGNER.BumpError):
                SIGNER.validate_bundles(self.app)
            path.write_bytes(original)
        (self.bundles[-1] / "Info.plist").unlink()
        with self.assertRaises(FileNotFoundError):
            SIGNER.validate_bundles(self.app)

    def test_only_containing_app_references_remapped(self):
        source = {"WKAppBundleIdentifier": SIGNER.ORIGINAL_ID,
            "CFBundleURLSchemes": [SIGNER.ORIGINAL_ID],
            "nested": {"NSExtensionContainingAppBundleIdentifier": SIGNER.ORIGINAL_ID}}
        result = SIGNER.remap_references(source, {SIGNER.ORIGINAL_ID: SIGNER.ROOT_ID})
        self.assertEqual(result["WKAppBundleIdentifier"], SIGNER.ROOT_ID)
        self.assertEqual(result["nested"]["NSExtensionContainingAppBundleIdentifier"], SIGNER.ROOT_ID)
        self.assertEqual(result["CFBundleURLSchemes"], [SIGNER.ORIGINAL_ID])
        self.assertEqual(source["WKAppBundleIdentifier"], SIGNER.ORIGINAL_ID)

    def test_signature_parser_returns_keys_without_values(self):
        xml = plistlib.dumps({"keychain-access-groups": ["private-marker"], "application-identifier": "private-marker"})
        entitlement = struct.pack(">II", 0xFADE7171, 8 + len(xml)) + xml
        signature = struct.pack(">III", 0xFADE0CC0, 20 + len(entitlement), 1) + struct.pack(">II", 5, 20) + entitlement
        header = struct.pack("<8I", 0xFEEDFACF, 0x100000C, 0, 2, 1, 16, 0, 0)
        data = header + struct.pack("<4I", 0x1D, 16, 48, len(signature)) + signature
        keys = SIGNER.signature_entitlement_keys(data)
        self.assertEqual(keys, {"keychain-access-groups", "application-identifier"})
        self.assertNotIn("private-marker", repr(keys))
        with self.assertRaises(SIGNER.BumpError):
            SIGNER.signature_entitlement_keys(data[:-1])

    def test_error_diagnostics_never_publish_untrusted_contents(self):
        self.assertEqual(SIGNER.safe_failure(RuntimeError("https://private.example/token?secret=private-marker")), "RuntimeError")
        self.assertEqual(SIGNER.safe_failure(RuntimeError("Apple API GET /v1/profiles/private-id failed (HTTP 403). private-marker")), "apple_api_get_profiles_http403")
        self.assertEqual(SIGNER.safe_failure(RuntimeError("A signing/tool command failed: codesign stage=verify_bundle reason=invalid_signature (exit 1) private-marker")), "codesign stage=verify_bundle reason=invalid_signature")


class ProfileTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        candidates = [SOURCE.parent, ROOT.parent / "scripts", Path("/workspace/scratch/bump/y3-reference/scripts")]
        directory = next((path for path in candidates if (path / "bereal-resign.py").is_file()), None)
        if directory is None:
            raise unittest.SkipTest("reviewed CI helper available in Y3 staging only")
        cls.module = SIGNER.load_signer(directory)

    def profile(self, grants=None):
        return {"Entitlements": {"application-identifier": "TESTTEAM00.*",
            "com.apple.developer.team-identifier": "TESTTEAM00", "get-task-allow": False,
            "keychain-access-groups": grants if grants is not None else ["TESTTEAM00.*"]}}

    def test_existing_wildcard_proves_own_and_common_keychain_groups(self):
        for suffix in SIGNER.SUFFIXES:
            identifier = SIGNER.ROOT_ID + suffix
            entitlements, common = SIGNER.bundle_entitlements(self.module, self.profile(), identifier)
            self.assertEqual(common, "TESTTEAM00." + SIGNER.ROOT_ID)
            self.assertEqual(set(entitlements["keychain-access-groups"]), {"TESTTEAM00." + identifier, common})
            self.assertNotIn("*", repr(entitlements))
            self.assertNotIn(SIGNER.ORIGINAL_ID, repr(entitlements))

    def test_narrow_or_foreign_keychain_grant_cannot_be_expanded(self):
        for grants in (["OTHERTEAM0.*"], ["TESTTEAM00.co.unrelated.*"], ["com.apple.token"]):
            with self.subTest(grants=grants), self.assertRaises(RuntimeError):
                SIGNER.bundle_entitlements(self.module, self.profile(grants), SIGNER.ROOT_ID + ".lpse")
        with self.assertRaises(RuntimeError):
            SIGNER.bundle_entitlements(self.module, self.profile(), "com.unrelated.application")

    def test_read_only_adapter_rejects_apple_write_before_dispatch(self):
        class API:
            def request(self, *args):
                raise AssertionError("write dispatched")
        for method in ("POST", "PATCH", "DELETE", "PUT"):
            with self.subTest(method=method), self.assertRaisesRegex(SIGNER.BumpError, "write_forbidden"):
                SIGNER.ReadOnlyAPI(API()).request(method, "/v1/profiles")


class IdentitySelectionTests(unittest.TestCase):
    def module(self):
        primary = (Path("primary.p12"), b"primary-cert", Path("primary-key.pem"), Path("api-key.p8"))
        alternate = (Path("alternate.p12"), b"alternate-cert", None, Path("api-key.p8"))
        module = SimpleNamespace()
        module.decode_identity = mock.Mock(side_effect=lambda root, need_private_key, **kwargs:
            alternate if kwargs.get("certificate_env") == "DIST_P12_BASE64" else primary)
        module.RefreshingAppleAPI = mock.Mock(return_value=object())
        module.signing_readiness = mock.Mock(return_value=({}, {"attributes": {"udid": "fixture-device"}}))
        module.select_existing_wildcard_profile = mock.Mock(return_value=(b"fixture-profile", {}))
        return module

    def test_primary_identity_used_when_both_alternate_variables_absent(self):
        module = self.module()
        with tempfile.TemporaryDirectory() as directory, mock.patch.dict(os.environ, {"APPLE_TEAM_ID": "TESTTEAM00"}, clear=True):
            result = SIGNER.prepare_identity(module, Path(directory), True)
        self.assertEqual(result[0], Path("primary.p12"))
        self.assertEqual(result[1], b"primary-cert")
        self.assertEqual(result[2], Path("primary-key.pem"))
        self.assertEqual(result[3], b"primary-cert")
        self.assertEqual(result[-2:], ("P12_PASSWORD", "existing_primary"))
        module.decode_identity.assert_called_once()
        module.signing_readiness.assert_called_once()
        self.assertEqual(module.select_existing_wildcard_profile.call_args.args[1], b"primary-cert")

    def test_alternate_identity_retains_primary_input_decryption_key(self):
        module = self.module()
        environment = {"APPLE_TEAM_ID": "TESTTEAM00", "DIST_P12_BASE64": "fixture", "DIST_P12_PASSWORD": "fixture"}
        with tempfile.TemporaryDirectory() as directory, mock.patch.dict(os.environ, environment, clear=True):
            result = SIGNER.prepare_identity(module, Path(directory), True)
        self.assertEqual(result[0], Path("alternate.p12"))
        self.assertEqual(result[1], b"primary-cert")
        self.assertEqual(result[2], Path("primary-key.pem"))
        self.assertEqual(result[3], b"alternate-cert")
        self.assertEqual(result[-2:], ("DIST_P12_PASSWORD", "existing_alternate"))
        self.assertEqual(module.decode_identity.call_count, 2)
        self.assertEqual(module.signing_readiness.call_count, 2)
        self.assertEqual(module.select_existing_wildcard_profile.call_args.args[1], b"alternate-cert")

    def test_partial_alternate_variables_rejected_before_decode(self):
        for name in ("DIST_P12_BASE64", "DIST_P12_PASSWORD"):
            module = self.module()
            with tempfile.TemporaryDirectory() as directory, mock.patch.dict(os.environ, {"APPLE_TEAM_ID": "TESTTEAM00", name: "fixture"}, clear=True):
                with self.subTest(name=name), self.assertRaisesRegex(SIGNER.BumpError, "incomplete_alternate"):
                    SIGNER.prepare_identity(module, Path(directory), False)
            module.decode_identity.assert_not_called()

    def test_alternate_device_must_match_and_profile_failure_remains_exact(self):
        module = self.module()
        module.signing_readiness.side_effect = [({}, {"attributes": {"udid": "first"}}), ({}, {"attributes": {"udid": "second"}})]
        environment = {"APPLE_TEAM_ID": "TESTTEAM00", "DIST_P12_BASE64": "fixture", "DIST_P12_PASSWORD": "fixture"}
        with tempfile.TemporaryDirectory() as directory, mock.patch.dict(os.environ, environment, clear=True):
            with self.assertRaisesRegex(SIGNER.BumpError, "registered_device_changed"):
                SIGNER.prepare_identity(module, Path(directory), False)
        module.select_existing_wildcard_profile.assert_not_called()
        module = self.module()
        module.select_existing_wildcard_profile.side_effect = RuntimeError("No existing wildcard Ad Hoc profile proves certificate compatibility")
        with tempfile.TemporaryDirectory() as directory, mock.patch.dict(os.environ, {"APPLE_TEAM_ID": "TESTTEAM00"}, clear=True):
            with self.assertRaises(RuntimeError) as error:
                SIGNER.prepare_identity(module, Path(directory), False)
        self.assertEqual(SIGNER.safe_failure(error.exception), "no_compatible_existing_wildcard_profile")


if __name__ == "__main__":
    unittest.main()
