#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
./Scripts/build-server.sh
if [[ "$(uname -s)" == Darwin ]]; then JDK="$(/usr/libexec/java_home -v 11)"; else JDK="${JAVA_HOME:-$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")}"; fi
mkdir -p .build/cloud-memory-tests
classpath='.build/cloud-server-package/lib/*:.build/cloud-memory-tests'
"$JDK/bin/javac" --release 11 -encoding UTF-8 -cp "$classpath" -d .build/cloud-memory-tests Android/tests/SyncExchangeTests.java Server/CloudServerMemoryTests.java
"$JDK/bin/java" -Xmx256m -cp "$classpath" local.studyplanner.CloudServerMemoryTests
