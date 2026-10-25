#!/usr/bin/env python3
"""Verify the vendored, fixed-version SSH dependencies before building."""
from pathlib import Path
import hashlib

root = Path(__file__).resolve().parents[1] / "Android/lib"
expected = {
    "jsch-2.28.8.jar": "2afca1357d816028f2ac33f22407d2488a68406682973949cebb1b8ea6688a8b",
    "bcprov-jdk18on-1.86.jar": "2af190b300cbb0b35e248ccf5f4a06b6072030aeb3da7a98ec73abe5b4cb371f",
}
for name, checksum in expected.items():
    if hashlib.sha256((root / name).read_bytes()).hexdigest() != checksum:
        raise SystemExit("SSH dependency checksum mismatch: " + name)
print("SSH dependencies: fixed-version SHA-256 verified")
