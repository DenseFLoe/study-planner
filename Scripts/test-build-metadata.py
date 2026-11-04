"""Packaging provenance regressions; all repositories and bundles are temporary."""

import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
SCRIPT = Path(__file__).with_name("build-metadata.py")
spec = importlib.util.spec_from_file_location("build_metadata", SCRIPT)
metadata = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metadata)


class BuildMetadataTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="study-build-metadata-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.git("init", "-q")
        self.git("config", "user.name", "Build Metadata Test")
        self.git("config", "user.email", "test@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        (self.root / ".gitignore").write_text("dist/\n")
        (self.root / "课程.swift").write_text("// original source\n")
        self.git("add", ".")
        self.git("commit", "-qm", "Fixture")

    def git(self, *arguments):
        return metadata.git(self.root, *arguments)

    def test_clean_revision_and_ignored_outputs(self):
        state = metadata.capture(self.root, "release")
        self.assertEqual(state["StudyPlannerSourceRevision"], self.git("rev-parse", "HEAD").decode().strip())
        self.assertEqual(state["StudyPlannerSourceIdentifier"], self.git("rev-parse", "--short", "HEAD").decode().strip())
        self.assertFalse(state["StudyPlannerSourceModified"])
        self.assertEqual(state["StudyPlannerBuildConfiguration"], "release")
        self.assertRegex(state["StudyPlannerBuildDate"], r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
        (self.root / "dist").mkdir()
        (self.root / "dist" / "output").write_text("generated data")
        self.assertEqual(metadata.source_state(self.root)["StudyPlannerSourceFingerprint"], state["StudyPlannerSourceFingerprint"])
        self.assertFalse(metadata.source_state(self.root)["StudyPlannerSourceModified"])

    def test_staged_unstaged_and_new_sources_are_identified(self):
        clean = metadata.source_state(self.root)
        (self.root / "课程.swift").write_text("// updated source\n")
        unstaged = metadata.source_state(self.root)
        self.assertTrue(unstaged["StudyPlannerSourceModified"])
        self.assertNotEqual(clean["StudyPlannerSourceIdentifier"], unstaged["StudyPlannerSourceIdentifier"])
        self.git("add", "课程.swift")
        self.assertEqual(metadata.source_state(self.root), unstaged)
        (self.root / "new.swift").write_text("// new source\n")
        untracked = metadata.source_state(self.root)
        self.assertTrue(untracked["StudyPlannerSourceModified"])
        self.assertNotEqual(untracked["StudyPlannerSourceIdentifier"], unstaged["StudyPlannerSourceIdentifier"])
        (self.root / "new.swift").write_text("// changed untracked source\n")
        self.assertNotEqual(metadata.source_state(self.root)["StudyPlannerSourceIdentifier"], untracked["StudyPlannerSourceIdentifier"])

    def test_deleted_source_is_detected(self):
        clean = metadata.source_state(self.root)
        (self.root / "课程.swift").unlink()
        deleted = metadata.source_state(self.root)
        self.assertTrue(deleted["StudyPlannerSourceModified"])
        self.assertNotEqual(deleted["StudyPlannerSourceFingerprint"], clean["StudyPlannerSourceFingerprint"])

    def make_plist(self):
        (self.root / "dist").mkdir(exist_ok=True)
        path = self.root / "dist" / "Info.plist"
        path.write_bytes(plistlib.dumps({"CFBundleShortVersionString": "1.6.3", "CFBundleVersion": "18"}))
        return path

    def test_capture_and_stamp_cli_preserve_version_and_boolean(self):
        path = self.make_plist()
        snapshot = self.root / "dist" / "metadata.json"
        subprocess.run([sys.executable, str(SCRIPT), "capture", str(self.root), "debug", str(snapshot)], check=True)
        subprocess.run([sys.executable, str(SCRIPT), "stamp", str(self.root), str(snapshot), str(path)], check=True)
        actual = plistlib.loads(path.read_bytes())
        self.assertEqual(actual["CFBundleShortVersionString"], "1.6.3")
        self.assertEqual(actual["CFBundleVersion"], "18")
        self.assertIs(actual["StudyPlannerSourceModified"], False)
        self.assertEqual(actual["StudyPlannerBuildConfiguration"], "debug")
        self.assertEqual(actual["StudyPlannerSourceRevision"], json.loads(snapshot.read_text())["StudyPlannerSourceRevision"])

    def test_source_edits_during_build_do_not_stamp_inaccurate_revision(self):
        path = self.make_plist()
        original = path.read_bytes()
        state = metadata.capture(self.root, "release")
        (self.root / "课程.swift").write_text("// changed during build\n")
        with self.assertRaisesRegex(ValueError, "Source changed during the build"):
            metadata.stamp(self.root, state, path)
        self.assertEqual(path.read_bytes(), original)

    def test_head_change_during_build_is_rejected_even_without_content_edits(self):
        path = self.make_plist()
        state = metadata.capture(self.root, "release")
        self.git("commit", "--allow-empty", "-qm", "New revision")
        with self.assertRaisesRegex(ValueError, "Source changed during the build"):
            metadata.stamp(self.root, state, path)

    def test_verify_cli_supports_non_plist_packages(self):
        (self.root / "dist").mkdir()
        snapshot = self.root / "dist" / "build-info.json"
        snapshot.write_text(json.dumps(metadata.capture(self.root, "release")))
        command = [sys.executable, str(SCRIPT), "verify", str(self.root), str(snapshot)]
        subprocess.run(command, check=True)
        original = snapshot.read_bytes()
        (self.root / "课程.swift").write_text("// edited during APK build\n")
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Source changed during the build", result.stderr)
        self.assertEqual(snapshot.read_bytes(), original)

    def test_missing_fingerprint_is_rejected(self):
        state = metadata.capture(self.root, "release")
        del state["StudyPlannerSourceFingerprint"]
        with self.assertRaisesRegex(ValueError, "Source changed during the build"):
            metadata.verify(self.root, state)

    def test_invalid_configuration_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "configuration"):
            metadata.capture(self.root, "relase")


if __name__ == "__main__":
    unittest.main()
