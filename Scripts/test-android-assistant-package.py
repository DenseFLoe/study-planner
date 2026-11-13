"""Inspect the delivered APK without installing it or opening a real assistant account."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import zipfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("apk", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    spec = importlib.util.spec_from_file_location("assets", root / "Android/prepare-assets.py")
    assets = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(assets)
    spec = importlib.util.spec_from_file_location("metadata", root / "Scripts/build-metadata.py")
    metadata = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(metadata)
    with zipfile.ZipFile(args.apk) as apk:
        assert apk.testzip() is None
        assert json.loads(apk.read("assets/assistant-contract.json")) == assets.assistant_contract(root)
        metadata.verify(root, json.loads(apk.read("assets/build-info.json")))
        state = json.loads(apk.read("assets/initial-state.json"))
        assert all(state[name] == [] for name in ("courses", "tasks", "fixedEvents", "completions"))
        assert not any(re.search(r"(?:workspace|conversations|\.env|\.jks|\.pem|\.key)(?:\.|/|$)", n, re.I) for n in apk.namelist())
        dex = b"".join(apk.read(name) for name in apk.namelist() if re.fullmatch(r"classes\d*\.dex", name))
        for name in ("Activity", "Protocol", "Tools", "Actions", "Runner", "History", "Session", "Vault", "Markdown", "Chart", "ChartView", "Insights", "InsightView", "ChangeSummary"):
            assert f"Llocal/studyplanner/Assistant{name};".encode() in dex, name
    aapt = Path(os.environ.get("STUDYPLANNER_ANDROID_BUILD_TOOLS", str(root / "Android/tools/sdk35/android-15"))) / "aapt2"
    badging = subprocess.check_output([str(aapt), "dump", "badging", str(args.apk)], text=True)
    versions = dict(re.findall(r"^(STUDYPLANNER_\w+)=(.+)$", (root / "Scripts/version.env").read_text(), re.M))
    assert f"versionName='{versions['STUDYPLANNER_VERSION']}'" in badging
    assert f"versionCode='{versions['STUDYPLANNER_BUILD']}'" in badging
    manifest = subprocess.check_output([str(aapt), "dump", "xmltree", str(args.apk), "--file", "AndroidManifest.xml"], text=True)
    activity = manifest.split('"local.studyplanner.AssistantActivity"', 1)[1].split("E: ", 1)[0]
    assert re.search(r"android:exported.*(?:false|0x0)", activity), activity
    print("Android assistant APK verified: 18 shared tools, native implementation, private Activity, source/version, ZIP integrity and empty initial state; no real API used")


if __name__ == "__main__":
    main()
