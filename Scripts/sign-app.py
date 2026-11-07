#!/usr/bin/env python3
"""Sign with a pinned local credential identity or Developer ID; never replace a configured identity."""
import argparse
import os
from pathlib import Path
import plistlib
import re
import secrets
import subprocess
import tempfile

CONFIG = Path.home() / "Library/Application Support/StudyPlannerBuild/signing-identity.txt"
LOCAL_CONFIG = CONFIG.with_name("local-vault-identity.txt")
LOCAL_NAME = "Study Planner Credential Signing"


def local_identity():
    if os.environ.get("STUDYPLANNER_ADHOC_SIGN") == "1" or not LOCAL_CONFIG.exists():
        return None
    fingerprint = LOCAL_CONFIG.read_text().strip().upper()
    output = run("/usr/bin/security", "find-identity", "-p", "codesigning").decode()
    found = re.findall(r'\b([0-9A-Fa-f]{40})\s+"' + re.escape(LOCAL_NAME) + '"', output)
    if not re.fullmatch(r"[0-9A-F]{40}", fingerprint) or fingerprint not in found:
        raise ValueError("固定的本机凭证签名身份不可用；请恢复原证书和私钥，不会重建身份或回退签名。")
    return fingerprint


def requirement(identifier, fingerprint):
    return f'identifier "{identifier}" and certificate leaf = H"{fingerprint}"'


def setup_local():
    if LOCAL_CONFIG.exists():
        local_identity()
        print("继续复用现有本机凭证签名身份。")
        return
    # Never silently replace an orphaned identity after a partial setup or lost configuration.
    existing = subprocess.run(["/usr/bin/security", "find-certificate", "-c", LOCAL_NAME], capture_output=True)
    if existing.returncode == 0:
        raise ValueError("已存在同名本机证书；请先恢复其指纹配置，不能自动生成新身份。")
    LOCAL_CONFIG.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    keychain = run("/usr/bin/security", "default-keychain", "-d", "user").decode().strip().strip('"')
    # Private material exists only in an owner-only temporary directory during import.
    # It is never stored in the repository, app bundle, cache, or command output.
    with tempfile.TemporaryDirectory(prefix="study-local-signing-") as folder:
        root = Path(folder)
        config = root / "certificate.cnf"
        config.write_text("[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=ext\n[dn]\nCN=" + LOCAL_NAME + "\n[ext]\nbasicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n")
        key, cert, package = root / "private.key", root / "certificate.pem", root / "identity.p12"
        old_umask = os.umask(0o077)
        try:
            run("/usr/bin/openssl", "req", "-new", "-x509", "-newkey", "rsa:3072", "-nodes", "-days", "3650",
                "-config", str(config), "-keyout", str(key), "-out", str(cert))
            password = secrets.token_hex(24)
            environment = dict(os.environ, STUDYPLANNER_IMPORT_PASSWORD=password)
            subprocess.run(["/usr/bin/openssl", "pkcs12", "-export", "-inkey", str(key), "-in", str(cert), "-out", str(package),
                            "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES", "-passout", "env:STUDYPLANNER_IMPORT_PASSWORD"],
                           env=environment, check=True, capture_output=True)
            run("/usr/bin/security", "import", str(package), "-k", keychain, "-P", password, "-T", "/usr/bin/codesign")
            fingerprint = run("/usr/bin/openssl", "x509", "-in", str(cert), "-noout", "-fingerprint", "-sha1").decode().strip().split("=")[-1].replace(":", "")
            with LOCAL_CONFIG.open("x") as output:
                os.chmod(LOCAL_CONFIG, 0o600)
                output.write(fingerprint + "\n")
        finally:
            os.umask(old_umask)
    local_identity()
    print("本机签名身份已保存在钥匙串；配置仅含公开指纹。")


def run(*args):
    return subprocess.run(args, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout


def developer_identities():
    output = run("/usr/bin/security", "find-identity", "-v", "-p", "codesigning").decode()
    return dict(re.findall(r'\b([0-9A-Fa-f]{40})\s+"(Developer ID Application: [^"\n]+)"', output))


def selected_identity():
    if os.environ.get("STUDYPLANNER_ADHOC_SIGN") == "1":
        return None  # Explicit CI / development opt-out.
    identities = developer_identities()
    configured = os.environ.get("STUDYPLANNER_SIGN_IDENTITY")
    if configured is None and CONFIG.exists():
        configured = CONFIG.read_text().strip()
    if configured is not None:
        if not re.fullmatch(r"[0-9A-Fa-f]{40}", configured) or configured.upper() not in identities:
            raise ValueError("配置的 Developer ID 签名身份不可用。请恢复证书和私钥；不会回退到临时签名。")
        return configured.upper()
    if len(identities) > 1:
        raise ValueError("发现多个 Developer ID 身份；请用 sign-app.py configure <证书指纹> 固定选择。")
    return next(iter(identities), None)


def configure(fingerprint):
    if not fingerprint or not re.fullmatch(r"[0-9A-Fa-f]{40}", fingerprint) or fingerprint.upper() not in developer_identities():
        raise ValueError("请先在钥匙串导入有效 Developer ID Application 证书及其私钥，再提供该证书的 SHA-1 指纹。")
    CONFIG.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = CONFIG.with_suffix(".tmp")
    try:
        with temporary.open("x") as output:
            os.chmod(temporary, 0o600)
            output.write(fingerprint.upper() + "\n")
        temporary.replace(CONFIG)
    finally:
        temporary.unlink(missing_ok=True)
    print("已固定本机 Developer ID 签名身份；仅保存公开指纹，私钥仍在钥匙串。")


def sign(app):
    local = local_identity()
    identity = local or selected_identity()
    mode = "local-vault" if local else ("developer-id" if identity else "ad-hoc")
    info = app / "Contents/Info.plist"
    metadata = plistlib.loads(info.read_bytes())
    metadata["StudyPlannerSigningMode"] = mode
    info.write_bytes(plistlib.dumps(metadata))
    if local:
        entitlement = Path(__file__).with_name("local-signing.entitlements")
        run("/usr/bin/codesign", "--force", "--sign", local, "--timestamp=none", "--options", "runtime",
            "--entitlements", str(entitlement), "--requirements", "=designated => " + requirement("local.studyplanner.mac", local), str(app))
    elif identity:
        # Apple's generated requirement retains the app identifier and developer team.
        run("/usr/bin/codesign", "--force", "--sign", identity, "--timestamp", str(app))
        run("/usr/bin/codesign", "--verify", "--strict", "-R",
            '=anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists', str(app))
    else:
        print("提示：缺少 Developer ID，仍使用临时签名；本包不能解决升级后的钥匙串重复授权。")
        run("/usr/bin/codesign", "--force", "--sign", "-", str(app))
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(app))
    print("签名模式：" + mode)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["configure", "check", "sign", "setup-local"])
    parser.add_argument("value", nargs="?")
    args = parser.parse_args()
    try:
        if args.action == "setup-local":
            setup_local()
        elif args.action == "configure":
            configure(args.value)
        elif args.action == "check":
            if local_identity():
                print("使用本机固定凭证组件与签名身份。")
            elif selected_identity() is None:
                print("未配置 Developer ID；本轮打包仍会使用临时签名。")
        else:
            if not args.value:
                parser.error("sign requires an app path")
            sign(Path(args.value))
    except ValueError as error:
        raise SystemExit(str(error))
    except subprocess.CalledProcessError as error:
        if error.cmd[0] == "/usr/bin/codesign":
            print(error.stderr.decode(errors="replace").strip())
        raise SystemExit("签名或钥匙串操作失败；未回退到其他签名。请检查钥匙串解锁状态和签名身份。")


if __name__ == "__main__":
    main()
