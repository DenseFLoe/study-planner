"""Signing selection regressions without real certificates or credentials."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("sign_app", Path(__file__).with_name("sign-app.py"))
signer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signer)


class SigningConfigurationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.config = Path(temporary.name) / "signing-identity.txt"
        for mocked in [patch.object(signer, "CONFIG", self.config), patch.object(signer, "LOCAL_CONFIG", self.config.with_name("local.txt")), patch.dict(os.environ, {}, clear=True)]:
            mocked.start()
            self.addCleanup(mocked.stop)
        self.first, self.second = "A" * 40, "B" * 40  # Public synthetic certificate fingerprints.

    def test_self_signed_and_invalid_certificates_are_not_developer_ids(self):
        output = f'1) {self.first} "Study Planner Local Signing"\n2) {self.second} "Developer ID Application: Fixture (EXAMPLE)"\n'
        with patch.object(signer, "run", return_value=output.encode()):
            self.assertEqual(signer.developer_identities(), {self.second: "Developer ID Application: Fixture (EXAMPLE)"})

    def test_no_certificate_reports_adhoc_and_one_valid_certificate_is_selected(self):
        with patch.object(signer, "developer_identities", return_value={}):
            self.assertIsNone(signer.selected_identity())
        with patch.object(signer, "developer_identities", return_value={self.first: "fixture"}):
            self.assertEqual(signer.selected_identity(), self.first)

    def test_configured_missing_identity_never_falls_back(self):
        self.config.write_text(self.first)
        with patch.object(signer, "developer_identities", return_value={self.second: "fixture"}):
            with self.assertRaises(ValueError):
                signer.selected_identity()

    def test_ambiguous_identity_requires_explicit_selection(self):
        with patch.object(signer, "developer_identities", return_value={self.first: "one", self.second: "two"}):
            with self.assertRaises(ValueError):
                signer.selected_identity()
            signer.configure(self.second)
            self.assertEqual(signer.selected_identity(), self.second)
            self.assertEqual(self.config.stat().st_mode & 0o777, 0o600)

    def test_explicit_ci_adhoc_does_not_access_keychain(self):
        with patch.dict(os.environ, {"STUDYPLANNER_ADHOC_SIGN": "1"}), patch.object(signer, "developer_identities") as lookup:
            self.assertIsNone(signer.selected_identity())
            lookup.assert_not_called()

    def test_local_identity_is_pinned_and_never_silently_regenerated(self):
        self.assertIsNone(signer.local_identity())
        signer.LOCAL_CONFIG.write_text(self.first)
        with patch.object(signer, "run", return_value=f'1) {self.first} "{signer.LOCAL_NAME}"'.encode()):
            self.assertEqual(signer.local_identity(), self.first)
        with patch.object(signer, "run", return_value=b"0 identities found"):
            with self.assertRaises(ValueError): signer.local_identity()

    def test_explicit_ci_disables_local_identity_without_keychain_access(self):
        signer.LOCAL_CONFIG.write_text(self.first)
        with patch.dict(os.environ, {"STUDYPLANNER_ADHOC_SIGN": "1"}), patch.object(signer, "run") as lookup:
            self.assertIsNone(signer.local_identity())
            lookup.assert_not_called()


if __name__ == "__main__":
    unittest.main()
