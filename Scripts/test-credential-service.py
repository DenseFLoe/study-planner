#!/usr/bin/env python3
"""Real XPC + Keychain acceptance using only a disposable, fixed dummy value."""
import importlib.util
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("sign_app", ROOT / "Scripts/sign-app.py")
signer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signer)


def run(*args, allowed=False):
    result = subprocess.run(list(map(str, args)), capture_output=True, text=True, timeout=45)
    if result.returncode and not allowed:
        raise RuntimeError(f"{Path(args[0]).name} failed ({result.returncode}): " + (result.stdout + result.stderr)[-2000:])
    return result


def main():
    identity = signer.local_identity()
    if not identity:
        raise SystemExit("Requires the configured local credential signing identity; real credentials are never used.")
    fixture = str(uuid.uuid4())
    with tempfile.TemporaryDirectory(prefix="study-credential-acceptance-") as temporary:
        root = Path(temporary)
        app = root / "Probe.app"
        macos = app / "Contents/MacOS"; macos.mkdir(parents=True)
        metadata = {"CFBundleIdentifier": "local.studyplanner.mac", "CFBundleExecutable": "StudyPlanner", "CFBundlePackageType": "APPL", "CFBundleVersion": "1"}
        info = app / "Contents/Info.plist"; info.write_bytes(plistlib.dumps(metadata))
        source = root / "main.swift"
        source.write_text('''import Foundation
import Security
let legacy = CommandLine.arguments[1].hasPrefix("legacy-")
let operation = CredentialRequest.Operation(rawValue: CommandLine.arguments[1].replacingOccurrences(of: "legacy-", with: ""))!
let request = CredentialRequest(operation, service: "local.studyplanner.credential-probe", account: CommandLine.arguments[2], value: operation == .save ? CredentialRequest.fixture : nil, interactive: false)
let (value, status) = legacy ? CredentialStore.perform(request) : CredentialClient.perform(request)
guard status == errSecSuccess else { print("FIXTURE_STATUS=\\(status)"); exit(2) }
if operation == .load && value != CredentialRequest.fixture { exit(3) }
print("FIXTURE_OK")
''')
        shared = ROOT / "Sources/StudyCredentials"
        run("/usr/bin/xcrun", "swiftc", "-swift-version", "5", "-module-cache-path", root / "cache",
            shared / "CredentialProtocol.swift", shared / "CredentialStore.swift", shared / "CredentialClient.swift", source, "-o", macos / "StudyPlanner")
        run(sys.executable, ROOT / "Scripts/build-credential-service.py", app)
        signer.sign(app)
        metadata = plistlib.loads(info.read_bytes())
        binary = macos / "StudyPlanner"
        service = app / "Contents/XPCServices/local.studyplanner.credentials.xpc"
        service_bytes = (service / "Contents/MacOS/CredentialService").read_bytes()
        saved_service = root / "service-original.xpc"
        shutil.copytree(service, saved_service)
        run(binary, "save", fixture)
        try:
            run(binary, "load", fixture)
            legacy_fixture = str(uuid.uuid4())
            run(binary, "legacy-save", legacy_fixture)
            try:
                assert run(binary, "load", legacy_fixture, allowed=True).returncode != 0
                assert run(binary, "save", legacy_fixture, allowed=True).returncode != 0
                run(binary, "legacy-load", legacy_fixture)
            finally:
                run(binary, "legacy-delete", legacy_fixture)
            print("Unauthorized legacy read/update preserved the original credential.", flush=True)
            print("Original signed client read passed without interaction.", flush=True)
            # Preserve all service bytes while replacing the host app identity's version hash.
            metadata = plistlib.loads(info.read_bytes()); metadata["CFBundleVersion"] = "2"
            info.write_bytes(plistlib.dumps(metadata)); signer.sign(app)
            run(binary, "load", fixture)
            run(sys.executable, ROOT / "Scripts/build-credential-service.py", app)
            assert (service / "Contents/MacOS/CredentialService").read_bytes() == service_bytes
            signer.sign(app)
            run(binary, "load", fixture)
            print("Updated client and repeated component packaging passed without interaction.", flush=True)
            # Same bundle ID, different signer must fail at the XPC service boundary.
            run("/usr/bin/codesign", "--force", "--sign", "-", app)
            assert run(binary, "load", fixture, allowed=True).returncode != 0
            signer.sign(app)
            # Same signer, wrong identifier must also fail (certificate possession alone is insufficient).
            metadata["CFBundleIdentifier"] = "local.studyplanner.unrelated"; info.write_bytes(plistlib.dumps(metadata))
            run("/usr/bin/codesign", "--force", "--sign", identity, "--timestamp=none", "--options", "runtime", app)
            assert run(binary, "load", fixture, allowed=True).returncode != 0
            metadata["CFBundleIdentifier"] = "local.studyplanner.mac"; info.write_bytes(plistlib.dumps(metadata)); signer.sign(app)
            run(binary, "load", fixture)
            # A substituted service is rejected before sending a save payload.
            run("/usr/bin/codesign", "--force", "--sign", "-", service); signer.sign(app)
            assert run(binary, "save", fixture, allowed=True).returncode != 0
            shutil.rmtree(service); shutil.copytree(saved_service, service); signer.sign(app)
            run(binary, "load", fixture)
            print("CREDENTIAL_SERVICE_PASS versions=2 untrustedClientRejected=1 wrongIdentifierRejected=1 substitutedServiceRejected=1 realCredentialsUsed=0", flush=True)
        finally:
            shutil.rmtree(service); shutil.copytree(saved_service, service)
            metadata["CFBundleIdentifier"] = "local.studyplanner.mac"; info.write_bytes(plistlib.dumps(metadata))
            signer.sign(app)
            run(binary, "delete", fixture)
            print("Disposable Keychain entry removed.", flush=True)


if __name__ == "__main__":
    main()
