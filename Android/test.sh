#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
JDK="$(/usr/libexec/java_home -v 11)"
mkdir -p Android/build/tests
"$JDK/bin/javac" -cp Android/tools/json.jar -d Android/build/tests Android/src/local/studyplanner/Planner.java Android/src/local/studyplanner/SchedulePreferenceOptimizer.java Android/src/local/studyplanner/SchedulePriorities.java Android/src/local/studyplanner/ScheduleExplanation.java Android/src/local/studyplanner/SyncLedger.java Android/src/local/studyplanner/DailyTaskOrdering.java Android/src/local/studyplanner/CourseTools.java Android/src/local/studyplanner/StudyLoad.java Android/src/local/studyplanner/ScheduleFeasibilitySearch.java Android/src/local/studyplanner/ScheduleHealth.java Android/src/local/studyplanner/DailyConsequences.java Android/src/local/studyplanner/DailyConsequenceRepository.java Android/src/local/studyplanner/WebsiteCapture.java Android/src/local/studyplanner/WebCourseImport.java Android/src/local/studyplanner/GenericCourseDigest.java Android/src/local/studyplanner/NetdiskImport.java Android/src/local/studyplanner/SyncJSON.java Android/src/local/studyplanner/SyncExchange.java Android/src/local/studyplanner/SyncTransfer.java Android/tests/SyncExchangeTests.java Android/tests/SyncJSONTests.java Android/tests/SyncMemoryTests.java Android/tests/SyncTransferTests.java Android/tests/PlannerTests.java Android/tests/FloatingEventTests.java Android/tests/EventConflictTests.java Android/tests/FixedOccurrenceTests.java Android/tests/AppReviewRegressionTests.java Android/tests/StudySettingsTests.java Android/tests/DesktopParityTests.java Android/tests/DailyTaskOrderingTests.java Android/tests/ImportParityTests.java Android/tests/LessonDeletionTests.java Android/tests/DailyConsequenceTests.java Android/tests/SchedulePreferenceTests.java Android/tests/JointFloatingSearchTests.java
"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/CourseSortSecurityTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.CourseSortSecurityTests
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.PlannerTests

"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.SchedulePreferenceTests

"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.FloatingEventTests

"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.JointFloatingSearchTests

"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.EventConflictTests

"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.FixedOccurrenceTests
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.AppReviewRegressionTests
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.StudySettingsTests
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.DesktopParityTests
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.DailyTaskOrderingTests
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.ImportParityTests
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.LessonDeletionTests
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.DailyConsequenceTests
node Android/tests/crawlers.test.js

"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.SyncTransferTests

"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.SyncJSONTests
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.SyncExchangeTests
"$JDK/bin/java" -Xmx256m -XX:-CompactStrings -cp Android/tools/json.jar:Android/build/tests local.studyplanner.SyncMemoryTests
