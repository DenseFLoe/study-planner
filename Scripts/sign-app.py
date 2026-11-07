#!/usr/bin/env python3
"""Sign updates with a pinned Apple Developer ID; never silently replace a configured identity."""
import argparse
import os
from pathlib import Path
import plistlib
import re
import subprocess

CONFIG = Path.home() / "Library/Application Support/StudyPlannerBuild/signing-identity.txt"


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
    identity = selected_identity()
    mode = "developer-id" if identity else "ad-hoc"
    info = app / "Contents/Info.plist"
    metadata = plistlib.loads(info.read_bytes())
    metadata["StudyPlannerSigningMode"] = mode
    info.write_bytes(plistlib.dumps(metadata))
    if identity:
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
    parser.add_argument("action", choices=["configure", "check", "sign"])
    parser.add_argument("value", nargs="?")
    args = parser.parse_args()
    try:
        if args.action == "configure":
            configure(args.value)
        elif args.action == "check":
            if selected_identity() is None:
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
