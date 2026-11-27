"""The signing identity stays within two explicitly authorized source CI jobs."""
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "ci/bump-resign.py"
if not SOURCE.is_file():
    SOURCE = ROOT.parent / "scripts/bump-resign.py"
SPEC = importlib.util.spec_from_file_location("bump_ci_scope_tests", SOURCE)
SIGNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SIGNER)
COMMIT = "a" * 40


class CIScopeTests(unittest.TestCase):
    def test_only_two_exact_authorized_repositories_on_main_are_allowed(self):
        for repository in ("444yttt/Y3POSClient", "444yttt/Y3FloorGuide"):
            with self.subTest(repository=repository):
                SIGNER.validate_ci_scope(repository, "refs/heads/main", COMMIT)

    def test_other_repositories_or_branches_are_rejected(self):
        for repository in (None, "", "other/Y3FloorGuide", "444yttt/Y3FloorGuide-fork", "444yttt/y3floorguide", "444yttt/Y3POSClient/extra"):
            with self.subTest(repository=repository), self.assertRaisesRegex(SIGNER.BumpError, "authorized_ci_scope_required"):
                SIGNER.validate_ci_scope(repository, "refs/heads/main", COMMIT)
        for ref in (None, "main", "refs/heads/debug", "refs/heads/main-other", "refs/tags/main", "refs/pull/1/merge"):
            with self.subTest(ref=ref), self.assertRaisesRegex(SIGNER.BumpError, "authorized_ci_scope_required"):
                SIGNER.validate_ci_scope("444yttt/Y3FloorGuide", ref, COMMIT)

    def test_source_commit_still_required_in_authorized_scope(self):
        for commit in (None, "", "a" * 39, "g" * 40, "A" * 40, "main"):
            with self.subTest(commit=commit), self.assertRaisesRegex(SIGNER.BumpError, "source_commit_missing"):
                SIGNER.validate_ci_scope("444yttt/Y3FloorGuide", "refs/heads/main", commit)


if __name__ == "__main__":
    unittest.main()
