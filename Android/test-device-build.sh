#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [ -z "${STUDYPLANNER_KEYSTORE_PASSWORD:-}" ]; then
  STUDYPLANNER_KEYSTORE_PASSWORD="$(security find-generic-password -s local.studyplanner.android.signing -a release -w 2>/dev/null || true)"
  export STUDYPLANNER_KEYSTORE_PASSWORD
fi
if [ -z "${STUDYPLANNER_KEYSTORE_PASSWORD:-}" ]; then
  echo '请先设置 STUDYPLANNER_KEYSTORE_PASSWORD，再构建设备测试 APK。' >&2
  exit 2
fi
JDK="$(/usr/libexec/java_home -v 11)"
BT="$PWD/tools/sdk35/android-15"
PLATFORM="$PWD/tools/sdk/android-35/android.jar"
KEYSTORE="${STUDYPLANNER_KEYSTORE_PATH:-$PWD/signing/release.jks}"
mkdir -p build/device-tests/classes build/device-tests/dex
"$BT/aapt2" link -o build/device-tests/base.apk -I "$PLATFORM" --manifest tests/device/AndroidManifest.xml
"$JDK/bin/javac" --release 8 -encoding UTF-8 -classpath "$PLATFORM:build/classes" -d build/device-tests/classes tests/device/*.java
"$JDK/bin/java" -cp "$BT/lib/d8.jar" com.android.tools.r8.D8 --min-api 26 --lib "$PLATFORM" --classpath build/classes --output build/device-tests/dex build/device-tests/classes/local/studyplanner/*.class
cp build/device-tests/base.apk build/device-tests/unsigned.apk
(cd build/device-tests/dex && zip -q ../unsigned.apk classes.dex)
"$BT/zipalign" -f 4 build/device-tests/unsigned.apk build/device-tests/aligned.apk
"$JDK/bin/java" -jar "$BT/lib/apksigner.jar" sign --ks "$KEYSTORE" --ks-pass env:STUDYPLANNER_KEYSTORE_PASSWORD --key-pass env:STUDYPLANNER_KEYSTORE_PASSWORD --out build/device-tests/tests.apk build/device-tests/aligned.apk
