#!/usr/bin/env python3
"""Reuse a signed XPC service byte-for-byte until its own source or signing identity changes."""
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import platform
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("sign_app", ROOT / "Scripts/sign-app.py")
signer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signer)
SERVICE = "local.studyplanner.credentials"


def build(app):
    fingerprint = signer.local_identity()
    destination = app / "Contents/XPCServices" / (SERVICE + ".xpc")
    info = app / "Contents/Info.plist"
    metadata = plistlib.loads(info.read_bytes())
    if not fingerprint:
        if destination.exists():
            shutil.rmtree(destination)
        metadata.pop("StudyPlannerCredentialServiceRequirement", None)
        info.write_bytes(plistlib.dumps(metadata))
        return
    sources = [ROOT / "Sources/StudyCredentials/CredentialProtocol.swift", ROOT / "Sources/StudyCredentials/CredentialStore.swift", ROOT / "Tools/CredentialService/main.swift"]
    digest = hashlib.sha256()
    for path in [Path(__file__).resolve(), *sources]:
        digest.update(path.read_bytes())
    digest.update(fingerprint.encode())
    architecture = platform.machine()
    if architecture not in ["arm64", "x86_64"]:
        raise ValueError("Unsupported native architecture")
    digest.update(architecture.encode())
    cache = signer.LOCAL_CONFIG.parent / "credential-service-cache" / digest.hexdigest()
    service = cache / (SERVICE + ".xpc")
    expected_requirement = signer.requirement(SERVICE, fingerprint)
    if not service.exists():
        cache.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        with tempfile.TemporaryDirectory(prefix="building-", dir=cache.parent) as folder:
            stage = Path(folder)
            bundle = stage / service.name
            macos = bundle / "Contents/MacOS"
            macos.mkdir(parents=True)
            data = {"CFBundleIdentifier": SERVICE, "CFBundleExecutable": "CredentialService", "CFBundleName": "学习日程凭证服务",
                    "CFBundlePackageType": "XPC!", "CFBundleVersion": "1", "LSMinimumSystemVersion": "14.0",
                    # File-based login Keychain access requires the caller's audit session.
                    "XPCService": {"ServiceType": "Application", "RunLoopType": "dispatch_main", "JoinExistingSession": True},
                    "StudyPlannerAllowedClient": signer.requirement("local.studyplanner.mac", fingerprint)}
            (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps(data))
            signer.run("/usr/bin/xcrun", "swiftc", "-swift-version", "5", "-O", "-target", architecture + "-apple-macosx14.0",
                       "-module-cache-path", str(Path(tempfile.gettempdir()) / "study-planner-credential-module-cache"),
                       *map(str, sources), "-o", str(macos / "CredentialService"))
            signer.run("/usr/bin/codesign", "--force", "--sign", fingerprint, "--timestamp=none", "--options", "runtime",
                       "--requirements", "=designated => " + expected_requirement, str(bundle))
            manifest = {str(p.relative_to(bundle)): hashlib.sha256(p.read_bytes()).hexdigest() for p in bundle.rglob("*") if p.is_file()}
            (stage / "manifest.json").write_text(json.dumps(manifest, sort_keys=True))
            # Atomic publication; interrupted builds never become reusable cache entries.
            stage.rename(cache)
        print("已生成固定凭证组件；仅组件本身更新时可能再次要求钥匙串授权。")
    manifest = json.loads((cache / "manifest.json").read_text())
    actual = {str(p.relative_to(service)): hashlib.sha256(p.read_bytes()).hexdigest() for p in service.rglob("*") if p.is_file()}
    if actual != manifest:
        raise ValueError("固定凭证组件缓存校验失败；未重新生成或覆盖。")
    signer.run("/usr/bin/codesign", "--verify", "--deep", "--strict", "-R", "=" + expected_requirement, str(service))
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(service, destination)
    metadata["StudyPlannerCredentialServiceRequirement"] = expected_requirement
    info.write_bytes(plistlib.dumps(metadata))
    print("已复用固定凭证组件，组件文件保持一致。")


if __name__ == "__main__":
    try:
        build(Path(sys.argv[1]).resolve())
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        if isinstance(error, subprocess.CalledProcessError) and error.cmd[0] in ["/usr/bin/xcrun", "/usr/bin/codesign"]:
            print(error.stderr.decode(errors="replace")[-3000:])
        if isinstance(error, (ValueError, OSError)):
            print(str(error))
        raise SystemExit("凭证组件构建或校验失败；未回退到直接读取钥匙串。")
