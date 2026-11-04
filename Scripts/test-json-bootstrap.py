"""Offline bootstrap regressions using temporary repositories and a fake transport."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).with_name("prepare-json-java.sh")
PIN = "3cf6cd6892e32e2b4c1c39e0f52f5248a2f5b37646fdfbb79a66b46b618414ed"
PAYLOAD = b"isolated JSON dependency fixture\n"


class JSONBootstrapTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="study-json-bootstrap-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / "Scripts").mkdir()
        script = SOURCE.read_text()
        self.assertEqual(script.count(PIN), 1)
        self.script = self.root / "Scripts/prepare-json-java.sh"
        self.script.write_text(script.replace(PIN, hashlib.sha256(PAYLOAD).hexdigest()))
        self.jar = self.root / "Android/tools/json.jar"
        self.jar.parent.mkdir(parents=True)
        (self.root / "payload").write_bytes(PAYLOAD)
        binaries = self.root / "bin"
        binaries.mkdir()
        transport = binaries / "curl"
        transport.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
root = pathlib.Path(os.environ["STUDY_BOOTSTRAP_ROOT"])
calls = root / "calls"
previous = calls.read_text().splitlines() if calls.exists() else []
with calls.open("a") as output: output.write(json.dumps(sys.argv[1:]) + "\\n")
target = pathlib.Path(sys.argv[sys.argv.index("--output") + 1])
if len(previous) < int(os.environ.get("STUDY_BOOTSTRAP_FAILURES", "0")):
    target.write_bytes(b"partial download")
    print(os.environ.get("STUDY_BOOTSTRAP_HTTP", "000"), end="")
    sys.exit(int(os.environ.get("STUDY_BOOTSTRAP_EXIT", "6")))
target.write_bytes(b"tampered" if os.environ.get("STUDY_BOOTSTRAP_CORRUPT") else (root / "payload").read_bytes())
print("200", end="")
''')
        transport.chmod(0o755)
        sleeper = binaries / "sleep"
        sleeper.write_text("#!/bin/sh\nexit 0\n")
        sleeper.chmod(0o755)
        self.environment = dict(os.environ, PATH=str(binaries) + os.pathsep + os.environ["PATH"], STUDY_BOOTSTRAP_ROOT=str(self.root))

    def run_script(self, **options):
        return subprocess.run(["bash", str(self.script)], cwd=self.root, env=dict(self.environment, **options),
                              capture_output=True, text=True, timeout=10)

    def calls(self):
        path = self.root / "calls"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def assert_clean_failure(self, result):
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.jar.exists())
        self.assertEqual(list(self.jar.parent.glob("json.jar.*")), [])

    def test_dns_failure_retries_and_only_publishes_verified_bytes(self):
        result = self.run_script(STUDY_BOOTSTRAP_FAILURES="2")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.jar.read_bytes(), PAYLOAD)
        self.assertEqual(len(self.calls()), 3)
        self.assertEqual(list(self.jar.parent.glob("json.jar.*")), [])
        for arguments in self.calls():
            self.assertIn("--connect-timeout", arguments)
            self.assertIn("--max-time", arguments)
            self.assertEqual(arguments[-1], "https://repo.maven.apache.org/maven2/org/json/json/20240303/json-20240303.jar")

    def test_retry_exhaustion_keeps_the_network_failure_and_no_cache(self):
        result = self.run_script(STUDY_BOOTSTRAP_FAILURES="99")
        self.assert_clean_failure(result)
        self.assertEqual(result.returncode, 6)
        self.assertEqual(len(self.calls()), 4)

    def test_temporary_http_failure_retries(self):
        result = self.run_script(STUDY_BOOTSTRAP_FAILURES="1", STUDY_BOOTSTRAP_EXIT="22", STUDY_BOOTSTRAP_HTTP="503")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.calls()), 2)

    def test_missing_artifact_is_not_retried(self):
        result = self.run_script(STUDY_BOOTSTRAP_FAILURES="99", STUDY_BOOTSTRAP_EXIT="22", STUDY_BOOTSTRAP_HTTP="404")
        self.assert_clean_failure(result)
        self.assertEqual(len(self.calls()), 1)

    def test_certificate_failure_is_not_retried(self):
        result = self.run_script(STUDY_BOOTSTRAP_FAILURES="99", STUDY_BOOTSTRAP_EXIT="60")
        self.assert_clean_failure(result)
        self.assertEqual(result.returncode, 60)
        self.assertEqual(len(self.calls()), 1)

    def test_checksum_failure_is_never_published_or_retried(self):
        result = self.run_script(STUDY_BOOTSTRAP_CORRUPT="1")
        self.assert_clean_failure(result)
        self.assertIn("checksum mismatch", result.stderr)
        self.assertEqual(len(self.calls()), 1)

    def test_valid_cache_needs_no_network(self):
        self.jar.write_bytes(PAYLOAD)
        self.assertEqual(self.run_script().returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_bad_cache_is_preserved_and_reported(self):
        self.jar.write_bytes(b"unexpected existing file")
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("checksum mismatch", result.stderr)
        self.assertEqual(self.jar.read_bytes(), b"unexpected existing file")
        self.assertEqual(self.calls(), [])


if __name__ == "__main__":
    unittest.main()
