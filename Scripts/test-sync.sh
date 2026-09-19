#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
Scripts/test.sh
JDK="$(/usr/libexec/java_home -v 11)"
mkdir -p Android/build/tests
"$JDK/bin/javac" -cp Android/tools/json.jar -d Android/build/tests Android/src/local/studyplanner/Planner.java Android/src/local/studyplanner/SyncLedger.java Android/tests/SyncTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.SyncTests
Scripts/test.sh --filter SyncLedgerTests/testWireFixtureAndJavaResponse
Android/test.sh
