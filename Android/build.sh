#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
JDK="$(/usr/libexec/java_home -v 11)"
BT="$PWD/tools/sdk35/android-15"
PLATFORM="$PWD/tools/sdk/android-35/android.jar"
KEYSTORE="${STUDYPLANNER_KEYSTORE_PATH:-$PWD/signing/release.jks}"
OUTPUT="${STUDYPLANNER_APK_OUTPUT:-$PWD/../dist/学习日程-安卓版.apk}"
rm -rf build/classes build/dex build/resources.zip build/base.apk build/unsigned.apk build/aligned.apk
mkdir -p build/classes build/dex signing
"$PWD/tools/sdk35/android-15/aapt2" compile --dir res -o build/resources.zip
"$PWD/tools/sdk35/android-15/aapt2" link -o build/base.apk -I "$PLATFORM" --manifest AndroidManifest.xml -A assets build/resources.zip
"$JDK/bin/javac" --release 8 -encoding UTF-8 -classpath "$PLATFORM:$PWD/lib/zxing-core-3.5.3.jar" -d build/classes src/local/studyplanner/*.java
"$JDK/bin/java" -cp "$BT/lib/d8.jar" com.android.tools.r8.D8 --min-api 26 --lib "$PLATFORM" --output build/dex build/classes/local/studyplanner/*.class "$PWD/lib/zxing-core-3.5.3.jar"
cp build/base.apk build/unsigned.apk
(cd build/dex && zip -q ../unsigned.apk classes.dex)
"$BT/zipalign" -f 4 build/unsigned.apk build/aligned.apk
if [ -z "${STUDYPLANNER_KEYSTORE_PASSWORD:-}" ]; then
  STUDYPLANNER_KEYSTORE_PASSWORD="$(security find-generic-password -s local.studyplanner.android.signing -a release -w 2>/dev/null || true)"
  export STUDYPLANNER_KEYSTORE_PASSWORD
fi
if [ -z "${STUDYPLANNER_KEYSTORE_PASSWORD:-}" ]; then
  echo '请先设置 STUDYPLANNER_KEYSTORE_PASSWORD，再构建签名 APK。' >&2
  exit 2
fi
if [ ! -f "$KEYSTORE" ]; then
  mkdir -p "$(dirname "$KEYSTORE")"
  "$JDK/bin/keytool" -genkeypair -keystore "$KEYSTORE" -storepass:env STUDYPLANNER_KEYSTORE_PASSWORD -keypass:env STUDYPLANNER_KEYSTORE_PASSWORD -alias studyplanner -dname 'CN=StudyPlanner, O=Local, C=CN' -keyalg RSA -keysize 3072 -validity 10000
  chmod 600 "$KEYSTORE"
fi
mkdir -p "$(dirname "$OUTPUT")"
"$JDK/bin/java" -jar "$BT/lib/apksigner.jar" sign --ks "$KEYSTORE" --ks-pass env:STUDYPLANNER_KEYSTORE_PASSWORD --key-pass env:STUDYPLANNER_KEYSTORE_PASSWORD --out "$OUTPUT" build/aligned.apk
"$JDK/bin/java" -jar "$BT/lib/apksigner.jar" verify --verbose "$OUTPUT"
"$PWD/tools/sdk35/android-15/aapt2" dump badging "$OUTPUT"
