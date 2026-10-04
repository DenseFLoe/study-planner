#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
JDK="$(/usr/libexec/java_home -v 11)"
mkdir -p Android/build/tests
"$JDK/bin/javac" -cp Android/tools/json.jar -d Android/build/tests Android/src/local/studyplanner/Planner.java Android/src/local/studyplanner/SyncLedger.java Android/tests/PlannerTests.java Android/tests/FloatingEventTests.java Android/tests/EventConflictTests.java Android/tests/FixedOccurrenceTests.java Android/tests/AppReviewRegressionTests.java Android/tests/StudySettingsTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.PlannerTests

"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.FloatingEventTests

"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.EventConflictTests

"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.FixedOccurrenceTests
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.AppReviewRegressionTests
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.StudySettingsTests
