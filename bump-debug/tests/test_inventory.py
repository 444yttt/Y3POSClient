"""Read-only profile inventory classification using synthetic private fixtures."""
import base64
import contextlib
import datetime as dt
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "ci/bump-resign.py"
if not SOURCE.is_file():
    SOURCE = ROOT.parent / "scripts/bump-resign.py"
SPEC = importlib.util.spec_from_file_location("bump_inventory_tests", SOURCE)
SIGNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SIGNER)

TEAM = "TEAMTEST00"
DEVICE = "private-device-marker"
CERTIFICATE = b"private-certificate-marker"
UUID = "2f8f66d6-18d4-4a95-bbb0-29a282d7b1d2"


def profile(grant="com.example.*", keychain=None):
    return {"UUID": UUID, "Name": "private-account-name-marker",
        "TeamIdentifier": [TEAM], "ApplicationIdentifierPrefix": [TEAM],
        "DeveloperCertificates": [CERTIFICATE], "ProvisionedDevices": [DEVICE],
        "CreationDate": dt.datetime(2020, 1, 1, tzinfo=dt.timezone.utc),
        "ExpirationDate": dt.datetime(2100, 1, 1, tzinfo=dt.timezone.utc),
        "Entitlements": {"application-identifier": TEAM + "." + grant,
            "com.apple.developer.team-identifier": TEAM, "get-task-allow": False,
            "keychain-access-groups": keychain if keychain is not None else [TEAM + ".*"]}}


def metadata():
    return {"uuid": UUID, "profileType": "IOS_APP_ADHOC", "profileState": "ACTIVE",
        "expirationDate": "2100-01-01T00:00:00Z"}


class InventoryAnalysisTests(unittest.TestCase):
    def analyze(self, candidate=None, attributes=None, identities=None, team=TEAM, device=DEVICE):
        return SIGNER.analyze_inventory_profile(profile() if candidate is None else candidate,
            {"existing_primary": CERTIFICATE} if identities is None else identities,
            team, device, metadata() if attributes is None else attributes)

    def test_valid_different_namespace_profile_produces_isolated_debug_candidate(self):
        result = self.analyze()
        self.assertEqual(result["application_identifier_grant"], "com.example.*")
        self.assertTrue(result["certificate_matches_existing_identity"])
        self.assertTrue(result["registered_device_set_matches"])
        self.assertTrue(result["current_validity"])
        self.assertTrue(result["team_matches_existing_identity"])
        self.assertTrue(result["application_prefix_consistent"])
        self.assertTrue(result["usable_ad_hoc_distribution"])
        self.assertEqual(result["compatible_isolated_debug_roots"], ["com.example.bumpdebug"])

    def test_unrestricted_wildcard_uses_task_debug_namespace(self):
        result = self.analyze(profile("*"))
        self.assertEqual(result["compatible_isolated_debug_roots"], ["com.ayato.bumpdebug"])

    def test_explicit_application_can_be_valid_without_nine_bundle_namespace(self):
        result = self.analyze(profile("com.example.existing-app"))
        self.assertTrue(result["usable_ad_hoc_distribution"])
        self.assertEqual(result["application_identifier_grant"], "com.example.existing-app")
        self.assertEqual(result["compatible_isolated_debug_roots"], [])

    def test_keychain_scope_must_cover_root_and_all_eight_extensions(self):
        for grants in ([TEAM + ".com.example.bumpdebug"], [TEAM + ".com.example.bumpdebug.lpse"],
                [TEAM + ".com.unrelated.*"], ["OTHERTEAM0.*"], ["com.apple.token"]):
            with self.subTest(grants=grants):
                result = self.analyze(profile(keychain=grants))
                self.assertEqual(result["compatible_isolated_debug_roots"], [])
        result = self.analyze(profile(keychain=[TEAM + ".com.example.*", "com.apple.token"]))
        self.assertEqual(result["compatible_isolated_debug_roots"], ["com.example.bumpdebug"])

    def test_certificate_match_accepts_either_existing_identity_without_reporting_bytes(self):
        identities = {"existing_primary": b"unmatched-primary", "existing_alternate": CERTIFICATE}
        result = self.analyze(identities=identities)
        self.assertTrue(result["certificate_matches_existing_identity"])
        self.assertTrue(result["usable_ad_hoc_distribution"])
        result = self.analyze(identities={"existing_primary": b"different-certificate"})
        self.assertFalse(result["certificate_matches_existing_identity"])
        self.assertFalse(result["usable_ad_hoc_distribution"])
        self.assertEqual(result["compatible_isolated_debug_roots"], [])
        self.assertTrue(result["current_validity"])

    def test_device_must_be_exact_registered_single_device(self):
        for devices in ([], ["different-device"], [DEVICE, "extra-device"], [DEVICE, DEVICE]):
            candidate = profile()
            candidate["ProvisionedDevices"] = devices
            with self.subTest(devices=devices):
                result = self.analyze(candidate)
                self.assertEqual(result["registered_device_included"], DEVICE in devices)
                self.assertFalse(result["registered_device_set_matches"])
                self.assertFalse(result["usable_ad_hoc_distribution"])
                self.assertEqual(result["compatible_isolated_debug_roots"], [])

    def test_dates_only_current_validity_rejects_expired_or_future_creation(self):
        for key, date in (("ExpirationDate", dt.datetime(2000, 1, 1, tzinfo=dt.timezone.utc)),
                ("CreationDate", dt.datetime(2101, 1, 1, tzinfo=dt.timezone.utc))):
            candidate = profile()
            candidate[key] = date
            with self.subTest(key=key):
                result = self.analyze(candidate)
                self.assertFalse(result["current_validity"])
                self.assertFalse(result["usable_ad_hoc_distribution"])
                self.assertEqual(result["compatible_isolated_debug_roots"], [])
        attributes = metadata()
        attributes["expirationDate"] = "2000-01-01T00:00:00Z"
        self.assertFalse(self.analyze(attributes=attributes)["current_validity"])

    def test_uuid_state_distribution_and_debug_grant_gate_aggregate_not_dates(self):
        for change in ({"uuid": "ee602466-4e49-432f-b1d6-dbd2ac8d5886"},
                       {"profileState": "INVALID"}, {"profileType": "IOS_APP_STORE"},
                       {"profileType": "IOS_APP_DEVELOPMENT"}):
            attributes = {**metadata(), **change}
            with self.subTest(change=change):
                result = self.analyze(attributes=attributes)
                self.assertTrue(result["current_validity"])
                self.assertFalse(result["usable_ad_hoc_distribution"])
                self.assertEqual(result["compatible_isolated_debug_roots"], [])
        candidate = profile()
        candidate["Entitlements"]["get-task-allow"] = True
        self.assertFalse(self.analyze(candidate)["usable_ad_hoc_distribution"])
        candidate = profile()
        candidate["ProvisionsAllDevices"] = True
        self.assertFalse(self.analyze(candidate)["usable_ad_hoc_distribution"])

    def test_team_and_application_prefix_mismatches_are_independent(self):
        candidate = profile()
        candidate["TeamIdentifier"] = ["OTHERTEAM0"]
        result = self.analyze(candidate)
        self.assertFalse(result["team_matches_existing_identity"])
        self.assertFalse(result["usable_ad_hoc_distribution"])
        candidate = profile()
        candidate["Entitlements"]["com.apple.developer.team-identifier"] = "OTHERTEAM0"
        self.assertFalse(self.analyze(candidate)["team_matches_existing_identity"])
        candidate = profile()
        candidate["ApplicationIdentifierPrefix"] = ["FOREIGN000"]
        result = self.analyze(candidate)
        self.assertFalse(result["application_prefix_consistent"])
        self.assertFalse(result["usable_ad_hoc_distribution"])
        self.assertEqual(result["compatible_isolated_debug_roots"], [])

    def test_normalized_keychain_grants_never_disclose_prefix_or_private_identity(self):
        candidate = profile(keychain=[TEAM + ".com.example.*", "OTHERTEAM0.*", "com.apple.token", "broken-grant"])
        result = self.analyze(candidate)
        scopes = result["keychain_grant_scopes"]
        self.assertIn({"scope": "com.example.*", "application_prefix_matches": True, "kind": "application"}, scopes)
        self.assertTrue(any(scope["kind"] == "application" and scope["application_prefix_matches"] is False for scope in scopes))
        self.assertTrue(any(scope["kind"] == "system" and scope["scope"] == "com.apple.token" for scope in scopes))
        self.assertTrue(any(scope["kind"] == "invalid" for scope in scopes))
        serialized = json.dumps(result)
        for private in (TEAM, "OTHERTEAM0", DEVICE, CERTIFICATE.decode(), "private-account-name-marker"):
            self.assertNotIn(private, serialized)

    def test_naive_profile_dates_are_treated_as_utc(self):
        candidate = profile()
        candidate["CreationDate"] = dt.datetime(2020, 1, 1)
        candidate["ExpirationDate"] = dt.datetime(2100, 1, 1)
        result = self.analyze(candidate)
        self.assertTrue(result["current_validity"])
        self.assertTrue(result["usable_ad_hoc_distribution"])

    def test_malformed_uuid_and_app_store_profile_never_offer_isolated_candidate(self):
        candidate = profile()
        candidate["UUID"] = "not-a-uuid"
        result = self.analyze(candidate)
        self.assertFalse(result["usable_ad_hoc_distribution"])
        self.assertEqual(result["compatible_isolated_debug_roots"], [])
        candidate = profile()
        candidate.pop("ProvisionedDevices")
        attributes = {**metadata(), "profileType": "IOS_APP_STORE"}
        result = self.analyze(candidate, attributes)
        self.assertFalse(result["usable_ad_hoc_distribution"])
        self.assertEqual(result["compatible_isolated_debug_roots"], [])


class InventoryPrivacyTests(unittest.TestCase):
    def test_cms_failures_export_only_safe_fixed_diagnostics(self):
        module = SimpleNamespace(run=mock.Mock(side_effect=RuntimeError(
            "https://private.example/token?secret=private-error-marker " + DEVICE)))
        result = SIGNER.inspect_inventory_cms(module, b"cms-fixture", {"existing_primary": CERTIFICATE}, TEAM, DEVICE, metadata())
        self.assertEqual(result, {"cms_signature_valid": False, "inspection_error": "RuntimeError"})
        self.assertNotIn("private-error-marker", json.dumps(result))
        self.assertNotIn(DEVICE, json.dumps(result))
        module.run.assert_called_once()
        module.run.reset_mock()
        self.assertEqual(SIGNER.inspect_inventory_cms(module, b"", {}, TEAM, DEVICE),
            {"cms_signature_valid": False, "inspection_error": "invalid_profile_content"})
        module.run.assert_not_called()

    def test_inventory_reads_existing_profiles_and_encrypts_namespace_report_only(self):
        active = {"type": "profiles", "id": "ADHOC1", "attributes": metadata()}
        full_active = {"type": "profiles", "id": "ADHOC1", "attributes": {
            **metadata(), "profileContent": base64.b64encode(b"cms-fixture").decode()}}
        store = {"type": "profiles", "id": "STORE1", "attributes": {
            "profileType": "IOS_APP_STORE", "profileState": "ACTIVE", "profileContent": "do-not-inspect"}}
        inactive = {"type": "profiles", "id": "EXPIRED1", "attributes": {
            "profileType": "IOS_APP_ADHOC", "profileState": "INVALID", "profileContent": "do-not-inspect"}}

        class API:
            def __init__(self):
                self.requests = []
                self.collections = []

            def collection(self, path, query=None):
                self.collections.append((path, query))
                if path != "/v1/profiles":
                    raise AssertionError("Unexpected inventory collection")
                return [active, store, inactive]

            def request(self, method, path, body=None):
                self.requests.append((method, path))
                if method != "GET" or path != "/v1/profiles/ADHOC1":
                    raise AssertionError("Unexpected inventory request or write")
                return {"data": full_active}

        api = API()
        commands, encrypted_plaintexts = [], []

        def run(arguments, data=None):
            commands.append(arguments)
            if arguments[1:3] == ["x509", "-inform"]:
                return b"-----BEGIN PUBLIC KEY-----\npublic-fixture\n-----END PUBLIC KEY-----\n"
            if arguments[1:3] == ["cms", "-verify"]:
                self.assertEqual(data, b"cms-fixture")
                return plistlib.dumps(profile())
            if arguments[1:3] == ["cms", "-encrypt"]:
                self.assertIn("-aes-256-gcm", arguments)
                self.assertEqual(arguments[-1], "bump-delivery-recipient.pem")
                plaintext = Path(arguments[arguments.index("-in") + 1]).read_text()
                encrypted_plaintexts.append(plaintext)
                Path(arguments[arguments.index("-out") + 1]).write_bytes(b"encrypted-fixture")
                return b""
            raise AssertionError("Unexpected tool invocation")

        def private(path, data):
            path.write_bytes(data)
            path.chmod(0o600)
            return path

        module = SimpleNamespace(decode_identity=mock.Mock(return_value=(Path("fixture.p12"), CERTIFICATE, None, Path("fixture.p8"))),
            RefreshingAppleAPI=mock.Mock(return_value=api),
            signing_readiness=mock.Mock(return_value=({"id": "CERT1"}, {"id": "DEVICE1", "attributes": {"udid": DEVICE}})),
            helper=SimpleNamespace(decode_base64=base64.b64decode), run=run, private=private)
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            work, private_root = temporary / "repo", temporary / "private"
            work.mkdir()
            private_root.mkdir()
            stdout = io.StringIO()
            previous = Path.cwd()
            try:
                os.chdir(work)
                with mock.patch.dict(os.environ, {"APPLE_TEAM_ID": TEAM, "GITHUB_SHA": "a" * 40}, clear=True), contextlib.redirect_stdout(stdout):
                    report = SIGNER.inventory_existing(module, private_root)
            finally:
                os.chdir(previous)
            summary = json.loads((work / "bump-public/inventory-summary.json").read_text())
            self.assertEqual(summary["api_profile_count"], 3)
            self.assertEqual(summary["active_ios_adhoc_count"], 1)
            self.assertEqual(summary["appstore_profile_count"], 1)
            self.assertEqual(summary["inactive_ios_adhoc_count"], 1)
            self.assertEqual(summary["compatible_isolated_namespace_profile_count"], 1)
            self.assertTrue(summary["inventory_complete"])
            self.assertFalse(summary["apple_resources_created_or_modified"])
            self.assertFalse(summary["signed_ipa_created"])
            self.assertEqual(api.requests, [("GET", "/v1/profiles/ADHOC1")])
            self.assertEqual([path for path, _ in api.collections], ["/v1/profiles"])
            self.assertEqual(len(encrypted_plaintexts), 1)
            self.assertIn("com.example.*", encrypted_plaintexts[0])
            self.assertEqual(json.loads(encrypted_plaintexts[0]), report)
            outside_private = "\n".join(path.read_text() for path in work.rglob("*") if path.is_file()) + stdout.getvalue()
            for marker in ("com.example", TEAM, DEVICE, CERTIFICATE.decode(), "private-account-name-marker"):
                self.assertNotIn(marker, outside_private)
            self.assertEqual({str(path.relative_to(work)) for path in work.rglob("*") if path.is_file()}, {
                "bump-public/signing-public-key.pem", "bump-public/inventory-summary.json",
                "bump-output/BumpLocationDebug-profile-inventory.cms"})


if __name__ == "__main__":
    unittest.main()
