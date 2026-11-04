"""Prepare a pinned official Android 35 API JAR for compile-only CI checks.

Tools remain in the ignored Android/tools directory. No SDK installer, account,
signing key, or machine-wide configuration is required.
"""

import hashlib
import os
from pathlib import Path
import tempfile
import urllib.request
import zipfile


URL = "https://dl.google.com/android/repository/platform-35_r02.zip"
ARCHIVE_SIZE = 64273788
ARCHIVE_SHA256 = "0988cacad01b38a18a47bac14a0695f246bc76c1b06c0eeb8eb0dc825ab0c8e0"
JAR_SHA256 = "4566663c3876e022b4fa4ced8c8697c4ab1688267f090114fd92d027b32e619b"
DESTINATION = Path(__file__).resolve().parent / "tools" / "api35" / "android.jar"


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def prepare():
    if DESTINATION.exists():
        if digest(DESTINATION) != JAR_SHA256:
            raise ValueError("Cached Android API JAR checksum mismatch; remove the invalid Android/tools/api35/android.jar and retry.")
        return DESTINATION
    DESTINATION.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="platform-download-", dir=DESTINATION.parent) as directory:
        archive = Path(directory) / "platform.zip"
        size = 0
        with urllib.request.urlopen(URL, timeout=60) as response, archive.open("wb") as out:
            while True:
                chunk = response.read(1024 * 1024)
                if not chunk:
                    break
                size += len(chunk)
                if size > ARCHIVE_SIZE:
                    raise ValueError("Android platform download exceeds the pinned archive size")
                out.write(chunk)
        if size != ARCHIVE_SIZE or digest(archive) != ARCHIVE_SHA256:
            raise ValueError("Android platform archive checksum/size mismatch")
        jar = Path(directory) / "android.jar"
        with zipfile.ZipFile(archive) as source:
            jar.write_bytes(source.read("android-35/android.jar"))
        if digest(jar) != JAR_SHA256:
            raise ValueError("Android API JAR checksum mismatch")
        os.replace(jar, DESTINATION)
    return DESTINATION


if __name__ == "__main__":
    print(prepare())
