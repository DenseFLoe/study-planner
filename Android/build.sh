#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
source "$PWD/../Scripts/version.env"
JDK="${JAVA_HOME:-}"
if [[ -z "$JDK" ]]; then
  if [[ "$(uname -s)" == Darwin ]]; then JDK="$(/usr/libexec/java_home -v 11)"
  elif command -v javac >/dev/null; then JDK="$(python3 -c 'import pathlib,shutil; print(pathlib.Path(shutil.which("javac")).resolve().parent.parent)')"
  else echo 'Set JAVA_HOME to a JDK 11 or newer installation.' >&2; exit 2; fi
fi
[[ -x "$JDK/bin/javac" ]] || { echo 'JAVA_HOME does not contain a Java compiler.' >&2; exit 2; }
BT="${STUDYPLANNER_ANDROID_BUILD_TOOLS:-$PWD/tools/sdk35/android-15}"
PLATFORM="${STUDYPLANNER_ANDROID_PLATFORM_JAR:-$PWD/tools/sdk/android-35/android.jar}"
KEYSTORE="${STUDYPLANNER_KEYSTORE_PATH:-$PWD/signing/release.jks}"
OUTPUT="${STUDYPLANNER_APK_OUTPUT:-$PWD/../dist/学习日程-安卓版.apk}"
[[ -x "$BT/aapt2" && -x "$BT/zipalign" && -f "$BT/lib/d8.jar" && -f "$BT/lib/apksigner.jar" && -f "$PLATFORM" ]] || {
  echo 'Android SDK tools/platform missing; set STUDYPLANNER_ANDROID_BUILD_TOOLS and STUDYPLANNER_ANDROID_PLATFORM_JAR.' >&2; exit 2;
}
rm -rf build/classes build/dex build/resources.zip build/base.apk build/unsigned.apk build/aligned.apk
mkdir -p build/classes build/dex signing
python3 ../Scripts/build-metadata.py capture .. release build/source-metadata.json
sed -E "s/android:versionCode=\"[0-9]+\"/android:versionCode=\"$STUDYPLANNER_BUILD\"/; s/android:versionName=\"[^\"]+\"/android:versionName=\"$STUDYPLANNER_VERSION\"/" AndroidManifest.xml > build/AndroidManifest.xml
"$BT/aapt2" compile --dir res -o build/resources.zip
python3 prepare-assets.py
cp build/source-metadata.json build/assets/build-info.json
"$BT/aapt2" link -o build/base.apk -I "$PLATFORM" --manifest build/AndroidManifest.xml -A build/assets build/resources.zip
python3 ../Scripts/verify-ssh-dependencies.py
"$JDK/bin/javac" --release 8 -encoding UTF-8 -classpath "$PLATFORM:$PWD/lib/*" -d build/classes src/local/studyplanner/*.java
"$JDK/bin/java" -cp "$BT/lib/d8.jar" com.android.tools.r8.D8 --min-api 26 --lib "$PLATFORM" --output build/dex build/classes/local/studyplanner/*.class "$PWD/lib/zxing-core-3.5.3.jar" "$PWD/lib/androidx-webkit-1.12.1.jar" "$PWD/lib/jsch-2.28.8.jar" "$PWD/lib/bcprov-jdk18on-1.86.jar"
cp build/base.apk build/unsigned.apk
(cd build/dex && zip -q ../unsigned.apk classes*.dex)
"$BT/zipalign" -f 4 build/unsigned.apk build/aligned.apk
python3 ../Scripts/build-metadata.py verify .. build/source-metadata.json
if [ -z "${STUDYPLANNER_KEYSTORE_PASSWORD:-}" ] && command -v security >/dev/null 2>&1; then
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
"$BT/aapt2" dump badging "$OUTPUT"
