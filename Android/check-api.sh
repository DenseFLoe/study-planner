#!/usr/bin/env bash
# Compile every Android source against Android's real API (no desktop JSON-java).
set -euo pipefail
cd "$(dirname "$0")/.."

JDK="${JAVA_HOME:-}"
if [[ -z "$JDK" ]]; then
  if [[ "$(uname -s)" == Darwin ]]; then
    JDK="$(/usr/libexec/java_home -v 11)"
  elif command -v javac >/dev/null; then
    JDK="$(python3 -c 'import pathlib,shutil; print(pathlib.Path(shutil.which("javac")).resolve().parent.parent)')"
  else
    echo 'A JDK is required. Set JAVA_HOME to a JDK 11 or newer installation.' >&2
    exit 2
  fi
fi
[[ -x "$JDK/bin/javac" ]] || { echo 'JAVA_HOME does not contain a Java compiler.' >&2; exit 2; }

# An existing SDK can be supplied explicitly; the default download is pinned and verified.
PLATFORM="${STUDYPLANNER_ANDROID_PLATFORM_JAR:-$(python3 Android/prepare-platform.py)}"
[[ -f "$PLATFORM" ]] || { echo 'Android platform JAR was not found.' >&2; exit 2; }
python3 Scripts/verify-ssh-dependencies.py
mkdir -p Android/build/api-check
"$JDK/bin/javac" --release 8 -encoding UTF-8 -classpath "$PLATFORM:$PWD/Android/lib/*" \
  -d Android/build/api-check Android/src/local/studyplanner/*.java
echo 'All Android sources compiled against the Android API; no APK or signing material was created.'
