#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
node Android/tests/crawlers.test.js
JDK="${JAVA_HOME:-$(/usr/libexec/java_home -v 11)}"
mkdir -p Android/build/tests
"$JDK/bin/javac" -cp Android/tools/json.jar -d Android/build/tests Android/src/local/studyplanner/Planner.java Android/src/local/studyplanner/ImmediateStudy.java Android/src/local/studyplanner/BackgroundCancellation.java Android/src/local/studyplanner/SavedScheduleAssessment.java Android/src/local/studyplanner/FixedEventTextParser.java Android/src/local/studyplanner/CompressedPreview.java Android/src/local/studyplanner/CloudSnapshot.java Android/tests/MigrationTests.java Android/src/local/studyplanner/SchedulePreferenceOptimizer.java Android/src/local/studyplanner/SchedulePriorities.java Android/src/local/studyplanner/ScheduleExplanation.java Android/src/local/studyplanner/CourseSourcePrivacy.java Android/src/local/studyplanner/NetdiskImportIdentity.java Android/src/local/studyplanner/SyncLedger.java Android/src/local/studyplanner/DailyTaskOrdering.java Android/src/local/studyplanner/DailyTaskSwapDraft.java Android/src/local/studyplanner/CourseTools.java Android/src/local/studyplanner/CourseMergeDraft.java Android/src/local/studyplanner/CourseEditing.java Android/src/local/studyplanner/CourseImportReceipt.java Android/src/local/studyplanner/CourseImportCatalog.java Android/src/local/studyplanner/StateMutation.java Android/src/local/studyplanner/ConfirmationDraft.java Android/src/local/studyplanner/PlannerBackupFile.java Android/src/local/studyplanner/PlannerBackupRepository.java Android/src/local/studyplanner/BoundedJSONFile.java Android/src/local/studyplanner/LocalRestoreBackup.java Android/src/local/studyplanner/TaskSearch.java Android/src/local/studyplanner/TaskSearchController.java Android/src/local/studyplanner/LatestWork.java Android/src/local/studyplanner/CourseFileSearch.java Android/src/local/studyplanner/SchedulePreview.java Android/src/local/studyplanner/WeeklyStudyStats.java Android/src/local/studyplanner/FixedEventEditing.java Android/src/local/studyplanner/LessonOrderDraft.java Android/src/local/studyplanner/SettingsEditing.java Android/src/local/studyplanner/SettingsDraft.java Android/src/local/studyplanner/StudyLoad.java Android/src/local/studyplanner/ScheduleFeasibilitySearch.java Android/src/local/studyplanner/ScheduleRestConflict.java Android/src/local/studyplanner/ScheduleHealth.java Android/src/local/studyplanner/DailyConsequences.java Android/src/local/studyplanner/DailyConsequenceRepository.java Android/src/local/studyplanner/WebsiteCapture.java Android/src/local/studyplanner/WebCourseImport.java Android/src/local/studyplanner/GenericCourseDigest.java Android/src/local/studyplanner/NetdiskImport.java Android/src/local/studyplanner/SyncJSON.java Android/src/local/studyplanner/SyncExchange.java Android/src/local/studyplanner/SyncTransfer.java Android/tests/SyncExchangeTests.java Android/tests/SyncJSONTests.java Android/tests/SyncMemoryTests.java Android/tests/SyncTransferTests.java Android/tests/PlannerTests.java Android/tests/FloatingEventTests.java Android/tests/EventConflictTests.java Android/tests/FixedOccurrenceTests.java Android/tests/AppReviewRegressionTests.java Android/tests/StudySettingsTests.java Android/tests/DesktopParityTests.java Android/tests/DailyTaskOrderingTests.java Android/tests/ImportParityTests.java Android/tests/LessonDeletionTests.java Android/tests/DailyConsequenceTests.java Android/tests/SchedulePreferenceTests.java Android/tests/JointFloatingSearchTests.java
"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/CourseSortSecurityTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.CourseSortSecurityTests
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.PlannerTests

"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.SchedulePreferenceTests

"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.FloatingEventTests
"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/FloatingCapacityBoundTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.FloatingCapacityBoundTests
"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/src/local/studyplanner/EventConflictReview.java Android/tests/FloatingReservationSearchTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.FloatingReservationSearchTests
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
"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/CourseImportCatalogTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.CourseImportCatalogTests
"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/src/local/studyplanner/CourseImportRequest.java Android/tests/CourseImportRequestTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.CourseImportRequestTests
"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/src/local/studyplanner/CourseImportPreview.java Android/tests/BackgroundCancellationTests.java Android/tests/CourseImportPreviewTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.BackgroundCancellationTests
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.CourseImportPreviewTests
"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/src/local/studyplanner/CourseCaptureIntake.java Android/tests/CourseCaptureIntakeTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.CourseCaptureIntakeTests

"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/src/local/studyplanner/CourseImportDetails.java Android/tests/CourseImportDetailsTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.CourseImportDetailsTests
"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/NetdiskImportIdentityTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.NetdiskImportIdentityTests
"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/WebImportRegressionTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.WebImportRegressionTests
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.LessonDeletionTests
"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/ScheduleRestConflictTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.ScheduleRestConflictTests
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.DailyConsequenceTests
"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/DailyConsequenceTargetTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.DailyConsequenceTargetTests
"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/DailyConsequenceSumTests.java
"$JDK/bin/java" -Xmx128m -cp Android/tools/json.jar:Android/build/tests local.studyplanner.DailyConsequenceSumTests
"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/DailyCompletionDateTests.java
"$JDK/bin/java" -Xmx128m -cp Android/tools/json.jar:Android/build/tests local.studyplanner.DailyCompletionDateTests
"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/DailyJournalIdentityTests.java
"$JDK/bin/java" -Xmx128m -cp Android/tools/json.jar:Android/build/tests local.studyplanner.DailyJournalIdentityTests
"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/DailyJournalProgressTests.java
"$JDK/bin/java" -Xmx128m -cp Android/tools/json.jar:Android/build/tests local.studyplanner.DailyJournalProgressTests
"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/BoundedJSONFileTests.java
"$JDK/bin/java" -Xmx128m -cp Android/tools/json.jar:Android/build/tests local.studyplanner.BoundedJSONFileTests
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
"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/CompletionDateIntegrityTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.CompletionDateIntegrityTests
"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/ProgressIntegrityTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.ProgressIntegrityTests
"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/CourseMergingIntegrityTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.CourseMergingIntegrityTests
"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/CourseMergeDraftTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.CourseMergeDraftTests
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
"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/RecurringRecognitionTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.RecurringRecognitionTests

"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/CourseEditingTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.CourseEditingTests
"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/src/local/studyplanner/CloudReplacement.java Android/src/local/studyplanner/CloudOutbox.java Android/src/local/studyplanner/CloudSyncEngine.java Android/tests/CloudSyncEngineTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.CloudSyncEngineTests

"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/FixedEventEditingTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.FixedEventEditingTests

"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/FixedOccurrenceRecoveryTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.FixedOccurrenceRecoveryTests

"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/src/local/studyplanner/EventConflictReview.java Android/tests/EventConflictReviewTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.EventConflictReviewTests

"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/LessonOrderDraftTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.LessonOrderDraftTests

"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/SettingsDraftTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.SettingsDraftTests

"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/SettingsNumberIntegrityTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.SettingsNumberIntegrityTests

"$JDK/bin/javac" -d Android/build/tests Android/src/local/studyplanner/DeferredRefresh.java Android/tests/DeferredRefreshTests.java
"$JDK/bin/java" -cp Android/build/tests local.studyplanner.DeferredRefreshTests

"$JDK/bin/javac" -d Android/build/tests Android/src/local/studyplanner/DailyRollover.java Android/tests/DailyRolloverTests.java
"$JDK/bin/java" -cp Android/build/tests local.studyplanner.DailyRolloverTests

"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/ConfirmationDraftTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.ConfirmationDraftTests

"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/src/local/studyplanner/ConfirmationReview.java Android/tests/ConfirmationReviewTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.ConfirmationReviewTests

"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/ReviewCandidateScaleTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.ReviewCandidateScaleTests

"$JDK/bin/javac" -d Android/build/tests Android/src/local/studyplanner/StateMutation.java Android/tests/StateMutationTests.java
"$JDK/bin/java" -cp Android/build/tests local.studyplanner.StateMutationTests

"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/PlannerBackupFileTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.PlannerBackupFileTests
"$JDK/bin/javac" -encoding UTF-8 -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/CourseSourcePrivacyTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.CourseSourcePrivacyTests
"$JDK/bin/java" -Xmx32m -cp Android/tools/json.jar:Android/build/tests local.studyplanner.CourseSourcePrivacyTests --large

"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/TaskSearchTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.TaskSearchTests
"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/src/local/studyplanner/CalendarDay.java Android/src/local/studyplanner/DayAgendaText.java Android/tests/DayAgendaTextTests.java Android/tests/CalendarDayTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.DayAgendaTextTests
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.CalendarDayTests
"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/OptionalTaskFieldsTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.OptionalTaskFieldsTests
"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/TaskMetadataTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.TaskMetadataTests

"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/src/local/studyplanner/CourseCatalog.java Android/tests/CourseCatalogTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.CourseCatalogTests

"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/src/local/studyplanner/FixedEventCatalog.java Android/tests/FixedEventCatalogTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.FixedEventCatalogTests

"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/SchedulePreviewTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.SchedulePreviewTests

"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/LocalRestoreBackupTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.LocalRestoreBackupTests

"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/WeeklyStudyStatsTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.WeeklyStudyStatsTests
"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/src/local/studyplanner/WeeklyStudyText.java Android/tests/WeeklyStudyTextTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.WeeklyStudyTextTests

"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/CourseFileSearchTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.CourseFileSearchTests

"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/LessonOrderScaleTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.LessonOrderScaleTests

"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/src/local/studyplanner/LessonOrderList.java Android/tests/LessonOrderListTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.LessonOrderListTests

"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/ManualLessonParseScaleTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.ManualLessonParseScaleTests

"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/ManualLessonTextTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.ManualLessonTextTests

"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/DailyTaskSwapDraftTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.DailyTaskSwapDraftTests

"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/CourseImportReceiptTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.CourseImportReceiptTests

"$JDK/bin/javac" --release 8 -encoding UTF-8 -d Android/build/tests Android/src/local/studyplanner/CloudSSHConfig.java Android/tests/SSHKeyImportTests.java
"$JDK/bin/java" -cp Android/build/tests local.studyplanner.SSHKeyImportTests

"$JDK/bin/javac" --release 8 -encoding UTF-8 -d Android/build/tests Android/src/local/studyplanner/CloudOperationGate.java Android/tests/CloudOperationGateTests.java
"$JDK/bin/java" -cp Android/build/tests local.studyplanner.CloudOperationGateTests

"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/src/local/studyplanner/WebsiteUpdatePolicy.java Android/tests/AndroidParityAdditionsTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.AndroidParityAdditionsTests
node Android/tests/website-login.test.cjs
