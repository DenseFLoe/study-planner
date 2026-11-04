"""Prepare the pinned official Linux x86_64 SDK 35 packaging tools in the workspace."""

import hashlib
import os
from pathlib import Path
import platform
import tempfile
import urllib.request
import zipfile


URL = "https://dl.google.com/android/repository/build-tools_r35_linux.zip"
ARCHIVE_SIZE = 61958799
# Also checked against Google's repository2-1.xml size and SHA-1 when pinned.
ARCHIVE_SHA256 = "bd3a4966912eb8b30ed0d00b0cda6b6543b949d5ffe00bea54c04c81e1561d88"
DESTINATION = Path(__file__).resolve().parent / "tools" / "build-tools35-linux"
FILES = {
    "aapt2": "d1096e11aba9c974644369ee3c50d239acac3f3428ffa928e5b9c14dfb7a57de",
    "zipalign": "a205d94a45c8522ca1b571dcbe190df145c818f0a29dfb366e4dd78eef4f56a7",
    "lib/d8.jar": "305622ad00535684534eb8f742cbf5e628a9abc09d8ea4d39d1babb95bf0cee5",
    "lib/apksigner.jar": "00ef9948f843fe395d2440ae3ef41405b8040a6d5d46493bd1902ac0ee6deae7",
    "lib64/libc++.so": "71c9f5d2e9d6e3e1875340c20a2f6b750c2c7f54f730f5fb7f1fd1d0877c8d6f",
    "lib64/libc++.so.1": "7eb2812ec39ab5c31f2fc9f906f412c713e76e0d07d6a6911108c7f886e24945",
    "core-lambda-stubs.jar": "c8a21e0e653227d1fce74bd547c9e7278e17c016c405aa8e1f6c313b192ade31",
    "source.properties": "084847d70abc41284feee7ea717e7c92eab0d1be05f048c27445a359cfe109d8",
    "NOTICE.txt": "14ad8a3f18a62e674e865b5e06b5847a6c97848d33f8cdc8e842eaf9bed994c3",
}


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def verify(directory):
    for name, expected in FILES.items():
        path = directory / name
        if not path.is_file() or path.is_symlink() or digest(path) != expected:
            raise ValueError(f"SDK build tool checksum mismatch: {path}")


def prepare():
    if platform.system() != "Linux" or platform.machine().lower() not in ("x86_64", "amd64"):
        raise RuntimeError("This pinned tool package requires Linux x86_64; supply an existing SDK on other systems.")
    if DESTINATION.exists():
        verify(DESTINATION)
        return DESTINATION
    DESTINATION.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="build-tools-download-", dir=DESTINATION.parent) as directory:
        archive = Path(directory) / "tools.zip"
        size = 0
        with urllib.request.urlopen(URL, timeout=60) as response, archive.open("wb") as out:
            while chunk := response.read(1024 * 1024):
                size += len(chunk)
                if size > ARCHIVE_SIZE:
                    raise ValueError("SDK download exceeds the pinned archive size")
                out.write(chunk)
        if size != ARCHIVE_SIZE or digest(archive) != ARCHIVE_SHA256:
            raise ValueError("SDK archive checksum/size mismatch")
        staged = Path(directory) / "verified"
        with zipfile.ZipFile(archive) as source:
            # Extract only the fixed allowlist, never paths supplied by the archive.
            for name in FILES:
                target = staged / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(source.read("android-15/" + name))
                target.chmod(0o755 if name in ("aapt2", "zipalign") else 0o644)
        verify(staged)
        os.replace(staged, DESTINATION)
    return DESTINATION


if __name__ == "__main__":
    print(prepare())
