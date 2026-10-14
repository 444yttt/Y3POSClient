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

    def test_reads_identifier_only_and_counts_universal_without_approving_signing(self):
        api = mock.Mock()
        api.collection.return_value = [registration(self.target, 'UNIVERSAL')]
        matches, ios, receipt = diagnostic.exact_registration_platform_probe(api, self.target)
        self.assertEqual(len(matches), 1)
        self.assertEqual(ios, [])
        self.assertEqual(receipt, {'exact_registration_count': 1, 'strict_ios_registration_count': 0,
                                 'exact_registration_platforms': ['UNIVERSAL'],
                                 'universal_registration_count': 1,
                                 'strict_ios_predicate_ignored_universal': True})
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
        matches, ios, receipt = diagnostic.exact_registration_platform_probe(api, self.target)
        self.assertEqual(len(matches), 5)
        self.assertEqual(len(ios), 1)
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
        matches, ios, receipt = diagnostic.exact_registration_platform_probe(api, self.target)
        self.assertEqual(matches, [])
        self.assertEqual(ios, [])
        self.assertEqual(receipt['exact_registration_count'], 0)
        self.assertEqual(receipt['exact_registration_platforms'], [])
        self.assertFalse(receipt['strict_ios_predicate_ignored_universal'])

    def test_audit_keeps_universal_registration_present_but_strict_profile_read_unapproved(self):
        signer, api = mock.Mock(), mock.Mock()
        signer.ROOT_ID = 'com.ayato.bereal493'
        signer.SAFE_SUFFIXES = ('', '.iMessageExtension', '.RealMojiNotificationContentExtension',
                                '.NotificationServiceExtension', '.Widgets')
        api.collection.side_effect = lambda path, filters: [registration(filters['filter[identifier]'], 'UNIVERSAL')]
        with mock.patch.dict(os.environ, {'APPLE_TEAM_ID': 'ABCDEFGHIJ'}):
            receipt = diagnostic.audit_exact_scoped_profiles(signer, api, b'certificate',
                                                           {'attributes': {'udid': 'PRIVATE-DEVICE'}})
        self.assertFalse(receipt['all_five_exact_scoped_profiles_verified'])
        self.assertEqual(receipt['confirmed_missing_registration_count'], 0)
        self.assertEqual(receipt['exact_scoped_signing_ready_count'], 0)
        self.assertEqual(api.collection.call_count, 5)
        self.assertTrue(all(not item['profile_read_allowed'] and item['exact_registration_count'] == 1
                            and item['strict_ios_predicate_ignored_universal'] for item in receipt['scoped_results']))
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
