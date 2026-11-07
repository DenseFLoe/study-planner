#!/usr/bin/env bash
# Exercise the real macOS packaging path without publishing or installing an app.
set -euo pipefail
cd "$(dirname "$0")/.."

# Reuse the debug build from the test suite; release packaging remains the default
# for manual build-dmg.sh invocations and user deliverables.
STUDYPLANNER_ADHOC_SIGN=1 ./Scripts/build-dmg.sh debug

python3 - <<'PY'
from pathlib import Path
import plistlib
import subprocess

root = Path.cwd()
dist = root / "dist"
metadata = plistlib.loads((dist / "学习日程.app/Contents/Info.plist").read_bytes())
revision = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
identifier = subprocess.check_output(["git", "rev-parse", "--short", "HEAD"], text=True).strip()
expected = {
    "StudyPlannerSourceRevision": revision,
    "StudyPlannerSourceIdentifier": identifier,
    "StudyPlannerBuildConfiguration": "debug",
}
for key, value in expected.items():
    if metadata.get(key) != value:
        raise SystemExit(f"Packaged {key} does not match this CI checkout")
if metadata.get("StudyPlannerSourceModified") is not False:
    raise SystemExit("CI packaging unexpectedly used modified sources")
checksum = f"学习日程-macOS-{identifier}.dmg.sha256"
subprocess.run(["shasum", "-a", "256", "-c", checksum], cwd=dist, check=True)
print(f"DMG packaging and source revision verified: {revision}")
PY
