"""Bounded Bump provisioning without network or real signing assets."""
import copy
import importlib.util
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "ci/bump-resign.py"
if not SOURCE.is_file():
    SOURCE = ROOT.parent / "scripts/bump-resign.py"
SPEC = importlib.util.spec_from_file_location("bump_provisioning_tests", SOURCE)
SIGNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SIGNER)

NAMES = {
    "com.ayato.bumpdebug": "BumpLocationDebug app",
    "com.ayato.bumpdebug.lpse": "BumpLocationDebug lpse",
    "com.ayato.bumpdebug.friend-widget": "BumpLocationDebug friend-widget",
    "com.ayato.bumpdebug.nce": "BumpLocationDebug nce",
    "com.ayato.bumpdebug.friend-intent": "BumpLocationDebug friend-intent",
    "com.ayato.bumpdebug.on-my-way-live-activity": "BumpLocationDebug on-my-way-live-activity",
    "com.ayato.bumpdebug.nse": "BumpLocationDebug nse",
    "com.ayato.bumpdebug.imessage-stickers-extension": "BumpLocationDebug imessage-stickers-extension",
    "com.ayato.bumpdebug.share": "BumpLocationDebug share",
}


def registration(identifier="com.ayato.bumpdebug", resource="BUNDLE1", platform="IOS"):
    return {"type": "bundleIds", "id": resource, "attributes": {"identifier": identifier, "platform": platform}}


def registration_body(identifier="com.ayato.bumpdebug"):
    return {"data": {"type": "bundleIds", "attributes": {
        "name": NAMES[identifier], "identifier": identifier, "platform": "IOS"}}}


def profile_body(identifier="com.ayato.bumpdebug", bundle="BUNDLE1"):
    name = NAMES[identifier].replace(" ", "-AdHoc-", 1)
    return {"data": {"type": "profiles", "attributes": {"name": name, "profileType": "IOS_APP_ADHOC"},
        "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bundle}},
            "certificates": {"data": [{"type": "certificates", "id": "CERT1"}]},
            "devices": {"data": [{"type": "devices", "id": "DEVICE1"}]}}}}


def candidate(content=True):
    attributes = {"profileType": "IOS_APP_ADHOC", "profileState": "ACTIVE", "expirationDate": "2099-01-01"}
    if content:
        attributes["profileContent"] = "fixture-content"
    return {"type": "profiles", "id": "PROFILE1", "attributes": attributes}


class FakeAPI:
    def __init__(self, collections=None, reads=None):
        self.collections = collections or {}
        self.reads = reads or {}
        self.collection_calls = []
        self.requests = []

    def collection(self, path, query=None):
        self.collection_calls.append((path, copy.deepcopy(query)))
        value = self.collections.get(path, [])
        if isinstance(value, Exception):
            raise value
        return copy.deepcopy(value)

    def request(self, method, path, body=None):
        self.requests.append((method, path, copy.deepcopy(body)))
        if method == "GET":
            value = self.reads.get(path, {"data": candidate()})
            if isinstance(value, Exception):
                raise value
            return copy.deepcopy(value)
        if path == "/v1/bundleIds":
            return {"data": {"type": "bundleIds", "id": "CREATED" + str(len(self.requests)),
                "attributes": copy.deepcopy(body["data"]["attributes"])}}
        if path == "/v1/profiles":
            return {"data": candidate()}
        raise AssertionError("Unexpected request dispatched")


class ScopedWriteGuardTests(unittest.TestCase):
    def guard(self, underlying=None):
        underlying = underlying or FakeAPI()
        return SIGNER.ScopedProvisioningAPI(underlying, "CERT1", "DEVICE1"), underlying

    def test_exact_nine_registration_and_profile_schemas_allowed(self):
        guard, underlying = self.guard()
        self.assertEqual(set(NAMES), {SIGNER.ROOT_ID + suffix for suffix in SIGNER.SUFFIXES})
        for identifier in NAMES:
            created = guard.request("POST", "/v1/bundleIds", registration_body(identifier))["data"]
            guard.accept_registration(created, identifier)
            guard.request("POST", "/v1/profiles", profile_body(identifier, created["id"]))
        self.assertEqual(len(underlying.requests), 18)
        self.assertTrue(all(method == "POST" for method, _, _ in underlying.requests))
        self.assertEqual({path for _, path, _ in underlying.requests}, {"/v1/bundleIds", "/v1/profiles"})

    def test_registration_foreign_scope_name_platform_or_fields_rejected(self):
        mutations = [
            lambda body: body["data"]["attributes"].update(identifier="com.unrelated.app"),
            lambda body: body["data"]["attributes"].update(identifier="com.ayato.bumpdebug.evil"),
            lambda body: body["data"]["attributes"].update(name="Unrelated app"),
            lambda body: body["data"]["attributes"].update(platform="MAC_OS"),
            lambda body: body["data"]["attributes"].update(platform="UNIVERSAL"),
            lambda body: body["data"]["attributes"].update(seedId="foreign"),
            lambda body: body["data"].update(type="certificates"),
            lambda body: body["data"].update(relationships={}),
            lambda body: body.update(extra=True),
        ]
        for mutate in mutations:
            guard, underlying = self.guard()
            body = registration_body()
            mutate(body)
            with self.subTest(body=body), self.assertRaises(SIGNER.BumpError):
                guard.request("POST", "/v1/bundleIds", body)
            self.assertEqual(underlying.requests, [])

    def test_profile_relationships_and_attributes_cannot_escape_scope(self):
        mutations = [
            lambda body: body["data"]["relationships"]["bundleId"]["data"].update(id="UNVALIDATED"),
            lambda body: body["data"]["relationships"]["bundleId"]["data"].update(type="certificates"),
            lambda body: body["data"]["relationships"]["certificates"]["data"][0].update(id="OTHER-CERT"),
            lambda body: body["data"]["relationships"]["devices"]["data"][0].update(id="OTHER-DEVICE"),
            lambda body: body["data"]["relationships"]["certificates"]["data"].append({"type": "certificates", "id": "CERT2"}),
            lambda body: body["data"]["relationships"]["devices"]["data"].append({"type": "devices", "id": "DEVICE2"}),
            lambda body: body["data"]["relationships"].update(other={"data": []}),
            lambda body: body["data"]["attributes"].update(profileType="IOS_APP_STORE"),
            lambda body: body["data"]["attributes"].update(name="Other profile"),
            lambda body: body["data"]["attributes"].update(extra=True),
            lambda body: body["data"].update(id="unexpected"),
        ]
        for mutate in mutations:
            guard, underlying = self.guard()
            guard.accept_registration(registration(), SIGNER.ROOT_ID)
            body = profile_body()
            mutate(body)
            with self.subTest(body=body), self.assertRaises(SIGNER.BumpError):
                guard.request("POST", "/v1/profiles", body)
            self.assertEqual(underlying.requests, [])

    def test_profile_requires_prior_validated_registration(self):
        guard, underlying = self.guard()
        with self.assertRaisesRegex(SIGNER.BumpError, "unvalidated_profile_bundle"):
            guard.request("POST", "/v1/profiles", profile_body())
        for item, identifier in [(registration("com.foreign.app"), "com.foreign.app"),
                                 (registration(platform="MAC_OS"), SIGNER.ROOT_ID),
                                 (registration(), SIGNER.ROOT_ID + ".lpse")]:
            with self.subTest(item=item), self.assertRaises(SIGNER.BumpError):
                guard.accept_registration(item, identifier)
        self.assertEqual(underlying.requests, [])

    def test_forbidden_verbs_endpoints_and_duplicate_writes_never_dispatch(self):
        for method, path in [("PATCH", "/v1/bundleIds/BUNDLE1"), ("DELETE", "/v1/profiles/PROFILE1"),
                ("POST", "/v1/certificates"), ("POST", "/v1/devices"),
                ("POST", "/v1/bundleIds/BUNDLE1/bundleIdCapabilities"), ("PUT", "/v1/profiles")]:
            guard, underlying = self.guard()
            with self.subTest(method=method, path=path), self.assertRaises(SIGNER.BumpError):
                guard.request(method, path, {})
            self.assertEqual(underlying.requests, [])
        guard, underlying = self.guard()
        guard.request("POST", "/v1/bundleIds", registration_body())
        with self.assertRaisesRegex(SIGNER.BumpError, "duplicate_scoped_bundle"):
            guard.request("POST", "/v1/bundleIds", registration_body())
        self.assertEqual(len(underlying.requests), 1)
        guard.accept_registration(registration(), SIGNER.ROOT_ID)
        guard.request("POST", "/v1/profiles", profile_body())
        with self.assertRaisesRegex(SIGNER.BumpError, "duplicate_scoped_profile"):
            guard.request("POST", "/v1/profiles", profile_body())
        self.assertEqual(len(underlying.requests), 2)


class ExactProfileFlowTests(unittest.TestCase):
    def setUp(self):
        self.certificate = {"id": "CERT1"}
        self.device = {"id": "DEVICE1", "attributes": {"udid": "fixture-device"}}
        self.module = SimpleNamespace(validate_profile=mock.Mock(return_value=(b"validated-profile", {"validated": True})))

    def select(self, api, create=False, identifier=None):
        return SIGNER.exact_profile(self.module, api, self.certificate, b"certificate-der", "TESTTEAM00",
            identifier or SIGNER.ROOT_ID, self.device, create)

    def test_existing_exact_profile_reused_without_writes(self):
        underlying = FakeAPI({"/v1/bundleIds": [registration()], "/v1/bundleIds/BUNDLE1/profiles": [candidate()]})
        result, changes = self.select(SIGNER.ReadOnlyAPI(underlying))
        self.assertEqual(result, (b"validated-profile", {"validated": True}))
        self.assertEqual(changes, {"created_bundle_count": 0, "created_profile_count": 0, "reused_profile_count": 1})
        self.assertEqual(underlying.requests, [])
        self.module.validate_profile.assert_called_once_with(candidate(), b"certificate-der", "TESTTEAM00", SIGNER.ROOT_ID, "fixture-device")

    def test_normal_mode_missing_resources_never_create(self):
        for collections, reason in [({}, "missing_scoped_bundle_registration"),
                ({"/v1/bundleIds": [registration()]}, "no_compatible_existing_exact_profile")]:
            underlying = FakeAPI(collections)
            with self.subTest(reason=reason), self.assertRaisesRegex(SIGNER.BumpError, reason):
                self.select(SIGNER.ReadOnlyAPI(underlying))
            self.assertEqual(underlying.requests, [])

    def test_creation_requires_explicit_guard_and_exact_certificate_device(self):
        underlying = FakeAPI()
        with self.assertRaisesRegex(SIGNER.BumpError, "explicit_scoped_provisioning"):
            self.select(SIGNER.ReadOnlyAPI(underlying), create=True)
        self.assertEqual(underlying.requests, [])
        guard = SIGNER.ScopedProvisioningAPI(underlying, "CERT1", "DEVICE1")
        result, changes = self.select(guard, create=True)
        self.assertEqual(result[0], b"validated-profile")
        self.assertEqual(changes, {"created_bundle_count": 1, "created_profile_count": 1, "reused_profile_count": 0})
        self.assertEqual([(method, path) for method, path, _ in underlying.requests], [("POST", "/v1/bundleIds"), ("POST", "/v1/profiles")])
        relationships = underlying.requests[-1][2]["data"]["relationships"]
        self.assertEqual(relationships["certificates"], {"data": [{"type": "certificates", "id": "CERT1"}]})
        self.assertEqual(relationships["devices"], {"data": [{"type": "devices", "id": "DEVICE1"}]})

    def test_get_failure_does_not_create_duplicate_profile(self):
        for failure_at in ("collection", "profile_read"):
            collections = {"/v1/bundleIds": [registration()], "/v1/bundleIds/BUNDLE1/profiles": [candidate(False)]}
            reads = {"/v1/profiles/PROFILE1": RuntimeError("fixture_read_failure")}
            if failure_at == "collection":
                collections["/v1/bundleIds/BUNDLE1/profiles"] = RuntimeError("fixture_read_failure")
            underlying = FakeAPI(collections, reads)
            guard = SIGNER.ScopedProvisioningAPI(underlying, "CERT1", "DEVICE1")
            with self.subTest(failure_at=failure_at), self.assertRaisesRegex(RuntimeError, "fixture_read_failure"):
                self.select(guard, create=True)
            self.assertTrue(all(method == "GET" for method, _, _ in underlying.requests))
            self.module.validate_profile.assert_not_called()

    def test_ambiguous_wrong_platform_or_foreign_scope_fail_before_write(self):
        for records, reason in [([registration(), registration(resource="BUNDLE2")], "ambiguous_bundle"),
                ([registration(platform="MAC_OS")], "unexpected_bundle")]:
            underlying = FakeAPI({"/v1/bundleIds": records})
            guard = SIGNER.ScopedProvisioningAPI(underlying, "CERT1", "DEVICE1")
            with self.subTest(records=records), self.assertRaisesRegex(SIGNER.BumpError, reason):
                self.select(guard, create=True)
            self.assertEqual(underlying.requests, [])
        underlying = FakeAPI()
        with self.assertRaisesRegex(SIGNER.BumpError, "unapproved_bundle_scope"):
            self.select(SIGNER.ScopedProvisioningAPI(underlying, "CERT1", "DEVICE1"), create=True, identifier="com.foreign.app")
        self.assertEqual(underlying.collection_calls, [])
        self.assertEqual(underlying.requests, [])

    def test_prefix_filter_noise_ignored_and_universal_exact_registration_reused(self):
        underlying = FakeAPI({"/v1/bundleIds": [registration("com.ayato.bumpdebug.extra", "OTHER"), registration(platform="UNIVERSAL")],
            "/v1/bundleIds/BUNDLE1/profiles": [candidate()]})
        result, changes = self.select(SIGNER.ReadOnlyAPI(underlying))
        self.assertEqual(result[0], b"validated-profile")
        self.assertEqual(changes["created_bundle_count"], 0)
        self.assertEqual(underlying.requests, [])


if __name__ == "__main__":
    unittest.main()
