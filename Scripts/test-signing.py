"""Verify update identity and Keychain continuity using disposable synthetic entries only."""
import os
import importlib.util
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import uuid

SIGNER = Path(__file__).with_name("sign-app.py").resolve()


def run(*args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, text=True, **kwargs).stdout


def main():
    environment = os.environ.copy()
    environment.pop("STUDYPLANNER_ADHOC_SIGN", None)
    os.environ.pop("STUDYPLANNER_ADHOC_SIGN", None)
    spec = importlib.util.spec_from_file_location("sign_app", SIGNER)
    signer = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(signer)
    if signer.selected_identity() is None:
        raise SystemExit("BLOCKED: 缺少 Developer ID；不能验证跨版本免钥匙串授权。自签名仍按 cdhash 隔离，不能替代该测试。")
    service = "local.studyplanner.signing-test." + str(uuid.uuid4())
    with tempfile.TemporaryDirectory(prefix="study-signing-test-") as folder:
        root = Path(folder)
        source = root / "probe.swift"
        source.write_text('''import Foundation
import Security
SecKeychainSetUserInteractionAllowed(false)
let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: CommandLine.arguments[1], kSecAttrAccount as String: "synthetic-fixture"]
let action = CommandLine.arguments[2]
var status: OSStatus
if action == "create" {
    var item = query
    item[kSecValueData as String] = Data("synthetic-fixture-not-a-real-credential".utf8)
    status = SecItemAdd(item as CFDictionary, nil)
} else if action == "delete" {
    status = SecItemDelete(query as CFDictionary)
} else {
    var item = query
    item[kSecReturnData as String] = true
    var result: CFTypeRef?
    status = SecItemCopyMatching(item as CFDictionary, &result)
    if status == errSecSuccess && result as? Data != Data("synthetic-fixture-not-a-real-credential".utf8) { exit(3) }
}
if status != errSecSuccess { print("Synthetic Keychain operation failed: \\(status)"); exit(2) }
print("SYNTHETIC_KEYCHAIN_OK")
''')
        app = root / "probe.app"
        macos = app / "Contents/MacOS"
        macos.mkdir(parents=True)
        metadata = {"CFBundleIdentifier": "local.studyplanner.mac", "CFBundleExecutable": "probe", "CFBundlePackageType": "APPL", "CFBundleVersion": "1"}
        plist = app / "Contents/Info.plist"
        plist.write_bytes(plistlib.dumps(metadata))
        binary = macos / "probe"
        run("swiftc", str(source), "-o", str(binary))
        run(sys.executable, str(SIGNER), "sign", str(app), env=environment)
        displayed = subprocess.run(["codesign", "-d", "-r-", str(app)], check=True, capture_output=True, text=True)
        requirement = next(line.split("designated => ", 1)[1] for line in (displayed.stdout + displayed.stderr).splitlines() if "designated => " in line)
        run(str(binary), service, "create")
        try:
            run(str(binary), service, "read")
            print("Original version Keychain read passed.", flush=True)
            # Changing a sealed resource produces a different code hash, just like an update.
            metadata["CFBundleVersion"] = "2"
            plist.write_bytes(plistlib.dumps(metadata))
            run(sys.executable, str(SIGNER), "sign", str(app), env=environment)
            run("codesign", "--verify", "--strict", "-R", "=" + requirement, str(app))
            assert "SYNTHETIC_KEYCHAIN_OK" in run(str(binary), service, "read")
            run(str(binary), service, "delete")
            # A matching bundle ID alone must never grant the same identity or vault access.
            run("codesign", "--force", "--sign", "-", str(app))
            rejected = subprocess.run(["codesign", "--verify", "-R", "=" + requirement, str(app)], capture_output=True)
            assert rejected.returncode != 0
        finally:
            run(sys.executable, str(SIGNER), "sign", str(app), env=environment)
            subprocess.run([str(binary), service, "delete"], capture_output=True)
        print("SIGNING_CONTINUITY_PASS versions=2 keychainPrompts=0 unrelatedSignerRejected=1 realCredentialsUsed=0")


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        # This harness handles synthetic fixtures only; keep errors narrow nonetheless.
        raise SystemExit(f"Signing continuity test failed (step {Path(error.cmd[0]).name}, action {error.cmd[-1]}, exit {error.returncode}): " + (error.stdout + error.stderr)[-1600:])
