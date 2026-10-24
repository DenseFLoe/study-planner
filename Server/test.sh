#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
./Scripts/build-server.sh
if [[ "$(uname -s)" == Darwin ]]; then JDK="$(/usr/libexec/java_home -v 11)"; else JDK="${JAVA_HOME:-$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")}"; fi
classpath="$PWD/.build/cloud-server-package/lib/json.jar:$PWD/.build/cloud-server-package/lib/study-planner-server.jar"
mkdir -p .build/cloud-server-tests
"$JDK/bin/javac" --release 11 -encoding UTF-8 -cp "$classpath" -d .build/cloud-server-tests Android/tests/SyncExchangeTests.java Server/CloudServerTests.java Server/CloudWireCheck.java
"$JDK/bin/java" -Xmx512m -cp "$classpath:$PWD/.build/cloud-server-tests" local.studyplanner.CloudServerTests
