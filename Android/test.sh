#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
node Android/tests/crawlers.test.js
JDK="${JAVA_HOME:-$(/usr/libexec/java_home -v 11)}"
mkdir -p Android/build/tests
"$JDK/bin/javac" -cp Android/tools/json.jar -d Android/build/tests Android/src/local/studyplanner/Planner.java Android/src/local/studyplanner/SavedScheduleAssessment.java Android/src/local/studyplanner/FixedEventTextParser.java Android/src/local/studyplanner/CompressedPreview.java Android/src/local/studyplanner/CloudSnapshot.java Android/tests/MigrationTests.java Android/src/local/studyplanner/SchedulePreferenceOptimizer.java Android/src/local/studyplanner/SchedulePriorities.java Android/src/local/studyplanner/ScheduleExplanation.java Android/src/local/studyplanner/SyncLedger.java Android/src/local/studyplanner/DailyTaskOrdering.java Android/src/local/studyplanner/CourseTools.java Android/src/local/studyplanner/StudyLoad.java Android/src/local/studyplanner/ScheduleFeasibilitySearch.java Android/src/local/studyplanner/ScheduleHealth.java Android/src/local/studyplanner/DailyConsequences.java Android/src/local/studyplanner/DailyConsequenceRepository.java Android/src/local/studyplanner/WebsiteCapture.java Android/src/local/studyplanner/WebCourseImport.java Android/src/local/studyplanner/GenericCourseDigest.java Android/src/local/studyplanner/NetdiskImport.java Android/src/local/studyplanner/SyncJSON.java Android/src/local/studyplanner/SyncExchange.java Android/src/local/studyplanner/SyncTransfer.java Android/tests/SyncExchangeTests.java Android/tests/SyncJSONTests.java Android/tests/SyncMemoryTests.java Android/tests/SyncTransferTests.java Android/tests/PlannerTests.java Android/tests/FloatingEventTests.java Android/tests/EventConflictTests.java Android/tests/FixedOccurrenceTests.java Android/tests/AppReviewRegressionTests.java Android/tests/StudySettingsTests.java Android/tests/DesktopParityTests.java Android/tests/DailyTaskOrderingTests.java Android/tests/ImportParityTests.java Android/tests/LessonDeletionTests.java Android/tests/DailyConsequenceTests.java Android/tests/SchedulePreferenceTests.java Android/tests/JointFloatingSearchTests.java
"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/CourseSortSecurityTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.CourseSortSecurityTests
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.PlannerTests

"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.SchedulePreferenceTests

"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.FloatingEventTests
"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/FloatingCapacityBoundTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.FloatingCapacityBoundTests
"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/FloatingDateCapacityTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.FloatingDateCapacityTests
"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/FixedEventDateCapacityTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.FixedEventDateCapacityTests
"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/FixedEventActualOverlapTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.FixedEventActualOverlapTests

"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.JointFloatingSearchTests

"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.EventConflictTests

"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.FixedOccurrenceTests
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.AppReviewRegressionTests
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.StudySettingsTests
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.DesktopParityTests
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.DailyTaskOrderingTests
"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/DailyTaskDateIntervalTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.DailyTaskDateIntervalTests
"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/DailyFloatingDateTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.DailyFloatingDateTests
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.ImportParityTests
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.LessonDeletionTests
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.DailyConsequenceTests
"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/DailyConsequenceTargetTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.DailyConsequenceTargetTests
"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/DailyConsequenceSumTests.java
"$JDK/bin/java" -Xmx128m -cp Android/tools/json.jar:Android/build/tests local.studyplanner.DailyConsequenceSumTests
"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/DailyJournalIdentityTests.java
"$JDK/bin/java" -Xmx128m -cp Android/tools/json.jar:Android/build/tests local.studyplanner.DailyJournalIdentityTests
"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/DailyJournalProgressTests.java
"$JDK/bin/java" -Xmx128m -cp Android/tools/json.jar:Android/build/tests local.studyplanner.DailyJournalProgressTests
# Compile the real controller against test-only UI boundaries; this is not an Android UI test.
mkdir -p Android/build/controller-tests
"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/controller-tests Android/tests/dailycontroller/*.java Android/src/local/studyplanner/DailyConsequenceController.java
"$JDK/bin/java" -Xmx128m -cp Android/build/controller-tests:Android/tools/json.jar:Android/build/tests local.studyplanner.DailyConsequenceControllerTests

"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.SyncTransferTests

"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.SyncJSONTests
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.SyncExchangeTests
"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/SyncTaskIntervalTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.SyncTaskIntervalTests
"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/CompletionNumberIntegrityTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.CompletionNumberIntegrityTests
"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/ProgressIntegrityTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.ProgressIntegrityTests
"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/CourseMergingIntegrityTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.CourseMergingIntegrityTests
"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/CourseNumberIntegrityTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.CourseNumberIntegrityTests
"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/TaskNumberIntegrityTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.TaskNumberIntegrityTests
"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/LegacyConfirmationIntegrityTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.LegacyConfirmationIntegrityTests
"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/ManualLessonArithmeticTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.ManualLessonArithmeticTests
"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/ManualLessonIdentityTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.ManualLessonIdentityTests
"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/ManualLessonNumberIntegrityTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.ManualLessonNumberIntegrityTests
"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/EventWindowIntegrityTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.EventWindowIntegrityTests
"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/SyncRecordValidationTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.SyncRecordValidationTests
"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/SyncScheduleIntegrityTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.SyncScheduleIntegrityTests
"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/CloudScheduleRepairTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.CloudScheduleRepairTests
"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/SyncScheduleStressTests.java
"$JDK/bin/java" -Xmx256m -cp Android/tools/json.jar:Android/build/tests local.studyplanner.SyncScheduleStressTests
"$JDK/bin/java" -Xmx256m -XX:-CompactStrings -cp Android/tools/json.jar:Android/build/tests local.studyplanner.SyncMemoryTests

"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.MigrationTests
