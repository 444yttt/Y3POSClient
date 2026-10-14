"""Offline checks for the GET-only exact-ID platform diagnostic."""
import importlib.util
import json
import os
from pathlib import Path
import unittest
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts' / 'bereal-access-diagnostics.py'
SPEC = importlib.util.spec_from_file_location('bereal_access_diagnostic', SCRIPT)
diagnostic = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(diagnostic)


def registration(target, platform, resource_id='PRIVATE-RESOURCE'):
    return {'id': resource_id, 'attributes': {'identifier': target, 'platform': platform}}


class ScopedPlatformProbeTests(unittest.TestCase):
    def setUp(self):
        self.target = diagnostic.SCOPED_TARGETS[0]

    def test_reads_identifier_only_and_counts_universal_ios_compatibility(self):
        api = mock.Mock()
        api.collection.return_value = [registration(self.target, 'UNIVERSAL')]
        matches, compatible, receipt = diagnostic.exact_registration_platform_probe(api, self.target)
        self.assertEqual(len(matches), 1)
        self.assertEqual(len(compatible), 1)
        self.assertEqual(receipt, {'exact_registration_count': 1, 'strict_ios_registration_count': 0,
                                 'compatible_registration_count': 1,
                                 'registration_policy_allowed_platforms': ['IOS', 'UNIVERSAL'],
                                 'exact_registration_platforms': ['UNIVERSAL'],
                                 'universal_registration_count': 1})
        filters = api.collection.call_args.args[1]
        self.assertEqual(filters['filter[identifier]'], self.target)
        self.assertNotIn('filter[platform]', filters)
        api.request.assert_not_called()

    def test_ignores_wide_prefix_results_and_sanitizes_unknown_platform(self):
        api = mock.Mock()
        api.collection.return_value = [
            registration(self.target + '.unrelated-private-app', 'PRIVATE-PLATFORM'),
            registration('com.unrelated.private', 'IOS'),
            registration(self.target, 'IOS'), registration(self.target, 'MAC_OS'),
            registration(self.target, 'UNIVERSAL'), registration(self.target, 'private-account-text'),
            registration(self.target, ['private-list'])]
        matches, compatible, receipt = diagnostic.exact_registration_platform_probe(api, self.target)
        self.assertEqual(len(matches), 5)
        self.assertEqual(len(compatible), 2)
        self.assertEqual(receipt['strict_ios_registration_count'], 1)
        self.assertEqual(receipt['exact_registration_platforms'], ['IOS', 'MAC_OS', 'OTHER', 'UNIVERSAL'])
        serialized = json.dumps(receipt)
        self.assertNotIn('private', serialized.lower())
        self.assertNotIn('PRIVATE-RESOURCE', serialized)

    def test_scope_outside_exact_five_is_rejected_before_any_read(self):
        api = mock.Mock()
        with self.assertRaises(RuntimeError):
            diagnostic.exact_registration_platform_probe(api, self.target + '.unapproved')
        api.collection.assert_not_called()

    def test_empty_registration_is_distinct_from_unknown_or_universal(self):
        api = mock.Mock()
        api.collection.return_value = []
        matches, compatible, receipt = diagnostic.exact_registration_platform_probe(api, self.target)
        self.assertEqual(matches, [])
        self.assertEqual(compatible, [])
        self.assertEqual(receipt['exact_registration_count'], 0)
        self.assertEqual(receipt['exact_registration_platforms'], [])
        self.assertEqual(receipt['compatible_registration_count'], 0)
        self.assertNotIn('strict_ios_predicate_ignored_universal', receipt)

    def audit_fixture(self):
        signer, api = mock.Mock(), mock.Mock()
        signer.ROOT_ID = 'com.ayato.bereal493'
        signer.SAFE_SUFFIXES = ('', '.iMessageExtension', '.RealMojiNotificationContentExtension',
                                '.NotificationServiceExtension', '.Widgets')
        def collection(path, filters):
            if path == '/v1/bundleIds':
                return [registration(filters['filter[identifier]'], 'UNIVERSAL')]
            return [{'id': 'PROFILE', 'attributes': {'profileType': 'IOS_APP_ADHOC',
                                                    'profileState': 'ACTIVE', 'profileContent': 'opaque'}}]
        api.collection.side_effect = collection
        return signer, api

    def test_universal_registration_requires_unchanged_strict_profile_proof(self):
        signer, api = self.audit_fixture()
        signer.validate_profile.side_effect = RuntimeError('incorrect certificate/device/CMS')
        with mock.patch.dict(os.environ, {'APPLE_TEAM_ID': 'ABCDEFGHIJ'}):
            receipt = diagnostic.audit_exact_scoped_profiles(signer, api, b'certificate',
                                                           {'attributes': {'udid': 'PRIVATE-DEVICE'}})
        self.assertFalse(receipt['all_five_exact_scoped_profiles_verified'])
        self.assertEqual(receipt['confirmed_missing_registration_count'], 0)
        self.assertEqual(receipt['exact_scoped_signing_ready_count'], 0)
        self.assertEqual(api.collection.call_count, 10)
        self.assertTrue(all(item['profile_read_allowed'] and item['exact_registration_count'] == 1
                            and item['compatible_registration_count'] == 1
                            and item['invalid_or_incompatible_profile_count'] == 1
                            for item in receipt['scoped_results']))
        self.assertEqual(signer.validate_profile.call_count, 5)
        self.assertTrue(all(call.args[1] == b'certificate' and call.args[2] == 'ABCDEFGHIJ'
                            and call.args[4] == 'PRIVATE-DEVICE' for call in signer.validate_profile.call_args_list))
        api.request.assert_not_called()

    def test_all_five_universal_registrations_ready_only_after_each_profile_validates(self):
        signer, api = self.audit_fixture()
        signer.validate_profile.return_value = (b'validated-CMS', {})
        with mock.patch.dict(os.environ, {'APPLE_TEAM_ID': 'ABCDEFGHIJ'}):
            receipt = diagnostic.audit_exact_scoped_profiles(signer, api, b'certificate',
                                                           {'attributes': {'udid': 'PRIVATE-DEVICE'}})
        self.assertTrue(receipt['all_five_exact_scoped_profiles_verified'])
        self.assertEqual(receipt['exact_scoped_signing_ready_count'], 5)
        self.assertEqual(signer.validate_profile.call_count, 5)
        self.assertEqual({call.args[3] for call in signer.validate_profile.call_args_list}, set(diagnostic.SCOPED_TARGETS))
        self.assertEqual(receipt['registration_policy_allowed_platforms'], ['IOS', 'UNIVERSAL'])
        api.request.assert_not_called()

    def test_mac_only_or_duplicate_exact_registration_never_becomes_ios_profile_proof(self):
        for platforms in (['MAC_OS'], ['UNIVERSAL', 'IOS'], ['UNIVERSAL', 'MAC_OS']):
            signer, api = self.audit_fixture()
            api.collection.side_effect = lambda path, filters: [registration(filters['filter[identifier]'], platform)
                                                                for platform in platforms]
            with self.subTest(platforms=platforms), mock.patch.dict(os.environ, {'APPLE_TEAM_ID': 'ABCDEFGHIJ'}):
                receipt = diagnostic.audit_exact_scoped_profiles(signer, api, b'certificate',
                                                               {'attributes': {'udid': 'PRIVATE-DEVICE'}})
            self.assertFalse(receipt['all_five_exact_scoped_profiles_verified'])
            self.assertEqual(receipt['exact_scoped_signing_ready_count'], 0)
            signer.validate_profile.assert_not_called()
            api.request.assert_not_called()

    def test_get_only_wrapper_rejects_all_resource_mutations(self):
        delegate = mock.Mock()
        api = diagnostic.ReadOnlyAPI(delegate)
        for method in ('POST', 'PATCH', 'DELETE'):
            with self.assertRaises(RuntimeError):
                api.request(method, '/v1/bundleIds')
        with self.assertRaises(RuntimeError):
            api.request('GET', '/v1/bundleIds', {'unapproved': 'body'})
        delegate.request.assert_not_called()


if __name__ == '__main__':
    unittest.main()
