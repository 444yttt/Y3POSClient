"""Provisioning allowlist subset guards; no Apple assets or network are used."""
import importlib.util
from pathlib import Path
import unittest


spec = importlib.util.spec_from_file_location('bereal_entitlement_subset', Path(__file__).parents[1] / 'scripts/bereal-resign.py')
signer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signer)
TEAM = 'ABCDEFGHIJ'


def profile(groups, identifier=signer.ROOT_ID):
    return {'Entitlements': {'application-identifier': TEAM + '.' + identifier,
            'com.apple.developer.team-identifier': TEAM, 'get-task-allow': False,
            'keychain-access-groups': groups}}


class EntitlementSubsetTest(unittest.TestCase):
    def test_unused_system_grant_is_omitted_without_mutating_profile(self):
        value = profile([TEAM + '.*', 'com.apple.token'])
        concrete = signer.concrete_entitlements(value, signer.ROOT_ID)
        self.assertEqual(concrete['keychain-access-groups'], [TEAM + '.' + signer.ROOT_ID])
        self.assertEqual(value['Entitlements']['keychain-access-groups'], [TEAM + '.*', 'com.apple.token'])

    def test_extension_keeps_only_its_approved_app_and_root_groups(self):
        identifier = signer.ROOT_ID + '.Widgets'
        value = profile(['com.apple.token', TEAM + '.*', TEAM + '.' + signer.ROOT_ID], identifier)
        concrete = signer.concrete_entitlements(value, identifier)
        self.assertEqual(concrete['keychain-access-groups'],
                         [TEAM + '.' + identifier, TEAM + '.' + signer.ROOT_ID])

    def test_token_only_grant_cannot_supply_app_keychain_permissions(self):
        with self.assertRaisesRegex(RuntimeError, 'no scoped app keychain grant'):
            signer.concrete_entitlements(profile(['com.apple.token']), signer.ROOT_ID)

    def test_other_foreign_grants_remain_rejected(self):
        for foreign in ('com.apple.token.child', 'com.apple.other', TEAM + '.com.other.app', 'OTHERTEAM1.*'):
            with self.subTest(foreign=foreign), self.assertRaisesRegex(RuntimeError, 'Unapproved profile keychain scope'):
                signer.concrete_entitlements(profile([TEAM + '.*', 'com.apple.token', foreign]), signer.ROOT_ID)


if __name__ == '__main__':
    unittest.main()
