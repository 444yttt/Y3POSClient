"""Existing wildcard registration/profile scope; no real Apple access."""
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "ci/bump-resign.py"
if not SOURCE.is_file():
    SOURCE = ROOT.parent / "scripts/bump-resign.py"
SPEC = importlib.util.spec_from_file_location("bump_existing_wildcard_tests", SOURCE)
SIGNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SIGNER)


def registration(grant="*", resource_id="WILDCARD1", platform="IOS"):
    return {"type": "bundleIds", "id": resource_id, "attributes": {"identifier": grant, "platform": platform}}


def profile_body():
    return {"data": {"type": "profiles", "attributes": {
        "name": "BumpLocationDebug-ExistingWildcard-AdHoc", "profileType": "IOS_APP_ADHOC"},
        "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": "WILDCARD1"}},
            "certificates": {"data": [{"type": "certificates", "id": "CERT1"}]},
            "devices": {"data": [{"type": "devices", "id": "DEVICE1"}]}}}}


class ExistingWildcardRegistrationTests(unittest.TestCase):
    def test_only_existing_wildcard_namespace_covering_all_nine_bundles_accepted(self):
        for grant in ("*", "com.*", "com.ayato.*"):
            for platform in ("IOS", "UNIVERSAL"):
                with self.subTest(grant=grant, platform=platform):
                    self.assertEqual(SIGNER.wildcard_registration(registration(grant, platform=platform)), ("WILDCARD1", grant))

    def test_explicit_foreign_incomplete_or_wrong_platform_registration_rejected(self):
        fixtures = [registration("com.example.*"), registration("com.ayato.bumpdebug"),
            registration("com.ayato.bumpdebug.*"), registration("com.aya*"), registration("com.ayato*"),
            registration(platform="MAC_OS"), registration(resource_id="../escape"),
            {**registration(), "type": "profiles"}]
        for fixture in fixtures:
            with self.subTest(fixture=fixture), self.assertRaises(SIGNER.BumpError):
                SIGNER.wildcard_registration(fixture)


class ExistingWildcardProfileGuardTests(unittest.TestCase):
    def guard(self):
        api = SimpleNamespace(request=mock.Mock(return_value={"data": {"id": "PROFILE1"}}))
        return SIGNER.ExistingWildcardProfileAPI(api, "CERT1", "DEVICE1", registration()), api

    def test_get_and_one_exact_profile_creation_allowed_without_bundle_mutation(self):
        guard, underlying = self.guard()
        guard.request("GET", "/v1/profiles/PROFILE1")
        result = guard.request("POST", "/v1/profiles", profile_body())
        self.assertEqual(result, {"data": {"id": "PROFILE1"}})
        self.assertEqual(underlying.request.call_count, 2)
        self.assertEqual(underlying.request.call_args.args, ("POST", "/v1/profiles", profile_body()))
        with self.assertRaises(SIGNER.BumpError):
            guard.request("POST", "/v1/profiles", profile_body())
        self.assertEqual(underlying.request.call_count, 2)

    def test_foreign_relations_names_distribution_and_extra_fields_fail_before_dispatch(self):
        mutations = [
            lambda body: body["data"]["attributes"].update(name="Unrelated profile"),
            lambda body: body["data"]["attributes"].update(profileType="IOS_APP_STORE"),
            lambda body: body["data"]["attributes"].update(extra=True),
            lambda body: body["data"].update(type="bundleIds"),
            lambda body: body["data"].update(extra=True),
            lambda body: body.update(extra=True),
            lambda body: body["data"]["relationships"]["bundleId"]["data"].update(id="OTHER-BUNDLE"),
            lambda body: body["data"]["relationships"]["certificates"]["data"][0].update(id="OTHER-CERT"),
            lambda body: body["data"]["relationships"]["devices"]["data"][0].update(id="OTHER-DEVICE"),
            lambda body: body["data"]["relationships"]["certificates"]["data"].append({"type": "certificates", "id": "CERT2"}),
            lambda body: body["data"]["relationships"]["devices"]["data"].append({"type": "devices", "id": "DEVICE2"}),
            lambda body: body["data"]["relationships"].update(extra={}),
        ]
        for mutate in mutations:
            guard, underlying = self.guard()
            body = profile_body()
            mutate(body)
            with self.subTest(body=body), self.assertRaises(SIGNER.BumpError):
                guard.request("POST", "/v1/profiles", body)
            underlying.request.assert_not_called()

    def test_all_other_write_verbs_and_endpoints_forbidden(self):
        for method, path in (("POST", "/v1/bundleIds"), ("POST", "/v1/certificates"),
                ("POST", "/v1/devices"), ("PATCH", "/v1/profiles/PROFILE1"),
                ("DELETE", "/v1/profiles/PROFILE1"), ("PUT", "/v1/profiles")):
            guard, underlying = self.guard()
            with self.subTest(method=method, path=path), self.assertRaises(SIGNER.BumpError):
                guard.request(method, path, {})
            underlying.request.assert_not_called()


class PrepareExistingWildcardTests(unittest.TestCase):
    def candidate(self, content=True):
        attributes = {"profileType": "IOS_APP_ADHOC", "profileState": "ACTIVE"}
        if content:
            attributes["profileContent"] = "fixture-profile-content"
        return {"type": "profiles", "id": "PROFILE1", "attributes": attributes}

    def api(self, registrations=None, candidates=None, read_failure=False):
        candidates = [self.candidate()] if candidates is None else candidates
        registrations = [registration()] if registrations is None else registrations
        api = SimpleNamespace()
        api.collection = mock.Mock(side_effect=lambda path, query=None:
            registrations if path == "/v1/bundleIds" else candidates if path == "/v1/bundleIds/WILDCARD1/profiles"
            else (_ for _ in ()).throw(AssertionError("Unexpected collection")))
        def request(method, path, body=None):
            if method == "GET" and read_failure:
                raise RuntimeError("fixture_api_read_failed")
            if method == "POST" and (path != "/v1/profiles" or body != profile_body()):
                raise AssertionError("Unscoped profile or other resource write")
            return {"data": self.candidate()}
        api.request = mock.Mock(side_effect=request)
        return api

    def module(self, api, compatibility=None):
        valid = {"application_identifier_kind": "wildcard", "compatible_scoped_identifiers": [SIGNER.ROOT_ID + suffix for suffix in SIGNER.SUFFIXES]}
        probe = mock.Mock(return_value=valid) if compatibility is None else mock.Mock(side_effect=compatibility)
        return SimpleNamespace(decode_identity=mock.Mock(return_value=(Path("fixture.p12"), b"fixture-cert", None, Path("fixture-api.p8"))),
            RefreshingAppleAPI=mock.Mock(return_value=api),
            signing_readiness=mock.Mock(return_value=({"id": "CERT1"}, {"id": "DEVICE1", "attributes": {"udid": "fixture-device"}})),
            probe_profile_compatibility=probe, run=mock.Mock(return_value=b"public-key-fixture"))

    def run_prepare(self, module, proof):
        with tempfile.TemporaryDirectory() as directory:
            previous = Path.cwd()
            try:
                os.chdir(directory)
                with mock.patch.dict(os.environ, {"APPLE_TEAM_ID": "TEAMTEST00", "GITHUB_SHA": "a" * 40}, clear=True), \
                     mock.patch.object(SIGNER, "existing_wildcard_proof", proof), contextlib.redirect_stdout(io.StringIO()):
                    return SIGNER.prepare_existing_wildcard(module, Path(directory))
            finally:
                os.chdir(previous)

    def test_matching_profile_is_reused_without_posting(self):
        api = self.api()
        module = self.module(api)
        proof = mock.Mock(return_value=(b"fixture-profile", {}))
        receipt = self.run_prepare(module, proof)
        self.assertEqual(receipt["created_bundle_count"], 0)
        self.assertEqual(receipt["created_profile_count"], 0)
        self.assertEqual(receipt["reused_profile_count"], 1)
        self.assertFalse(receipt["apple_resources_created_or_modified"])
        self.assertTrue(receipt["existing_bundle_registration_unchanged"])
        api.request.assert_not_called()
        proof.assert_called_once()
        module.probe_profile_compatibility.assert_called_once()

    def test_only_valid_existing_grant_proof_allows_one_bound_profile_creation(self):
        api = self.api()
        valid = {"application_identifier_kind": "wildcard", "compatible_scoped_identifiers": [SIGNER.ROOT_ID + suffix for suffix in SIGNER.SUFFIXES]}
        module = self.module(api, [RuntimeError("existing_certificate_mismatch"), valid])
        proof = mock.Mock(return_value=(b"fixture-profile", {}))
        receipt = self.run_prepare(module, proof)
        self.assertEqual(receipt["created_bundle_count"], 0)
        self.assertEqual(receipt["created_profile_count"], 1)
        self.assertEqual(receipt["reused_profile_count"], 0)
        api.request.assert_called_once_with("POST", "/v1/profiles", profile_body())
        self.assertEqual(proof.call_count, 2)
        self.assertEqual(module.probe_profile_compatibility.call_count, 2)
        api = self.api()
        module = self.module(api)
        proof = mock.Mock(side_effect=SIGNER.BumpError("fixture_invalid_grant"))
        with self.assertRaisesRegex(SIGNER.BumpError, "no_current_existing_wildcard_profile_grant_proof"):
            self.run_prepare(module, proof)
        api.request.assert_not_called()
        module.probe_profile_compatibility.assert_not_called()

    def test_ambiguous_or_missing_existing_registration_never_writes(self):
        for registrations, reason in (([registration(), registration("com.ayato.*", "OTHER1")], "not_unique"),
                ([registration("com.example.*")], "missing")):
            api = self.api(registrations=registrations)
            module = self.module(api)
            proof = mock.Mock(return_value=(b"fixture-profile", {}))
            with self.subTest(reason=reason), self.assertRaisesRegex(SIGNER.BumpError, reason):
                self.run_prepare(module, proof)
            api.request.assert_not_called()
            self.assertEqual(api.collection.call_count, 1)
            proof.assert_not_called()

    def test_failed_existing_profile_read_never_triggers_creation(self):
        api = self.api(candidates=[self.candidate(False)], read_failure=True)
        module = self.module(api)
        proof = mock.Mock(return_value=(b"fixture-profile", {}))
        with self.assertRaisesRegex(RuntimeError, "fixture_api_read_failed"):
            self.run_prepare(module, proof)
        api.request.assert_called_once_with("GET", "/v1/profiles/PROFILE1")
        proof.assert_not_called()
        module.probe_profile_compatibility.assert_not_called()


if __name__ == "__main__":
    unittest.main()
