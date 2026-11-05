#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/version.env
if [[ "$(uname -s)" == Darwin ]]; then
  JDK="${JAVA_HOME:-$(/usr/libexec/java_home -v 11)}"
else
  JDK="${JAVA_HOME:-$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")}"
fi
bash Scripts/prepare-json-java.sh
stage="$PWD/.build/cloud-server-package"
classes="$PWD/.build/cloud-server-classes"
rm -rf -- "$classes" "$stage"
mkdir -p "$classes" "$stage/lib" dist
json_source="$PWD/Android/tools/json.jar"
sources=()
for name in Planner BackgroundCancellation SchedulePreferenceOptimizer SchedulePriorities ScheduleExplanation DailyTaskOrdering CourseTools StudyLoad ScheduleFeasibilitySearch ScheduleRestConflict ScheduleHealth SavedScheduleAssessment WebCourseImport CourseSourcePrivacy NetdiskImportIdentity SyncLedger SyncJSON SyncExchange CloudSnapshot; do
  sources+=("Android/src/local/studyplanner/$name.java")
done
"$JDK/bin/javac" --release 11 -encoding UTF-8 -cp "$json_source" -d "$classes" "${sources[@]}" Server/src/local/studyplanner/*.java
"$JDK/bin/jar" --create --file "$stage/lib/study-planner-server.jar" -C "$classes" .
cp "$json_source" "$stage/lib/json.jar"
cp Server/{README.md,install.sh,start.sh,backup.sh,install-user.sh,start-user.sh,backup-user.sh,server.env.example,study-planner-sync.service,JSON-java-LICENSE.txt} "$stage/"
chmod +x "$stage/"*.sh
printf '%s (%s)\n' "$STUDYPLANNER_VERSION" "$STUDYPLANNER_BUILD" > "$stage/VERSION"
COPYFILE_DISABLE=1 tar --no-xattrs -czf "$PWD/dist/学习日程-云同步服务端.tar.gz" -C "$stage" .
echo "服务端部署包已生成：$PWD/dist/学习日程-云同步服务端.tar.gz"
