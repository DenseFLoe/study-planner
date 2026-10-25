#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 Scripts/verify-ssh-dependencies.py
if [[ "$(uname -s)" == Darwin ]]; then JDK="$(/usr/libexec/java_home -v 11)"; else JDK="${JAVA_HOME:-$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")}"; fi
mkdir -p Android/build/ssh-tests
"$JDK/bin/javac" --release 8 -encoding UTF-8 -cp 'Android/lib/*' -d Android/build/ssh-tests Android/src/local/studyplanner/CloudSSHConfig.java Android/src/local/studyplanner/CloudSSHTunnel.java Android/tests/CloudSSHTests.java
"$JDK/bin/java" -Xmx128m -cp 'Android/lib/*:Android/build/ssh-tests' local.studyplanner.CloudSSHTests
./Scripts/test.sh --filter 'CloudSSHTests|CloudSyncClientTests'
