#!/usr/bin/env bash
# Validate actual APK packaging with a disposable key; never use a release key.
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/version.env
STUDYPLANNER_ANDROID_BUILD_TOOLS="$(python3 Android/prepare-build-tools.py)"
STUDYPLANNER_ANDROID_PLATFORM_JAR="$(python3 Android/prepare-platform.py)"
export STUDYPLANNER_ANDROID_BUILD_TOOLS STUDYPLANNER_ANDROID_PLATFORM_JAR

umask 077
apk_check_dir="$(mktemp -d "${TMPDIR:-/tmp}/study-planner-apk-check.XXXXXX")"
trap 'rm -rf -- "$apk_check_dir"' EXIT
export STUDYPLANNER_KEYSTORE_PATH="$apk_check_dir/validation-only.jks"
export STUDYPLANNER_APK_OUTPUT="$apk_check_dir/validation-only.apk"
STUDYPLANNER_KEYSTORE_PASSWORD="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
export STUDYPLANNER_KEYSTORE_PASSWORD
if ! bash Android/build.sh > "$apk_check_dir/build.log" 2>&1; then
  cat "$apk_check_dir/build.log"
  exit 1
fi

python3 - "$STUDYPLANNER_APK_OUTPUT" "$STUDYPLANNER_BUILD" "$STUDYPLANNER_VERSION" "$STUDYPLANNER_ANDROID_BUILD_TOOLS/aapt2" <<'PY'
import json
from pathlib import Path
import runpy
import subprocess
import sys
import zipfile

apk, build, version, aapt = sys.argv[1:]
badging = subprocess.check_output([aapt, "dump", "badging", apk], text=True)
expected = f"package: name='local.studyplanner.android' versionCode='{build}' versionName='{version}'"
if expected not in badging or "minSdkVersion:'26'" not in badging or "targetSdkVersion:'35'" not in badging:
    raise SystemExit("Packaged application identity/version/SDK does not match the source configuration")
with zipfile.ZipFile(apk) as bundle:
    for name in ("AndroidManifest.xml", "classes.dex", "assets/initial-state.json", "assets/snapshot-info.json", "assets/build-info.json"):
        if name not in bundle.namelist():
            raise SystemExit(f"APK is missing {name}")
    with bundle.open("classes.dex") as dex:
        if dex.read(4) != b"dex\n":
            raise SystemExit("APK DEX header is invalid")
    metadata = json.loads(bundle.read("assets/build-info.json"))
    runpy.run_path("Scripts/build-metadata.py")["verify"](Path.cwd(), metadata)
    if metadata.get("StudyPlannerBuildConfiguration") != "release" or not metadata.get("StudyPlannerBuildDate"):
        raise SystemExit("APK build metadata is incomplete")
    state = json.loads(bundle.read("assets/initial-state.json"))
    for field in ("courses", "fixedEvents", "tasks", "completions"):
        if state[field] != []:
            raise SystemExit("APK unexpectedly contains personal planner records")
print(f"APK resources, DEX, signature, source revision, version {version} ({build}) and empty initial state verified")
PY
