#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
JDK="$(/usr/libexec/java_home -v 11)"
mkdir -p Android/build/tests
"$JDK/bin/javac" -cp Android/tools/json.jar -d Android/build/tests Android/src/local/studyplanner/Planner.java Android/tests/PlannerTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.PlannerTests
