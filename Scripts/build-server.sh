#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/version.env
if [[ "$(uname -s)" == Darwin ]]; then
  JDK="$(/usr/libexec/java_home -v 11)"
else
  JDK="${JAVA_HOME:-$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")}"
fi
stage="$PWD/.build/cloud-server-package"
classes="$PWD/.build/cloud-server-classes"
rm -rf -- "$classes" "$stage"
mkdir -p "$classes" "$stage/lib" dist
json_source="$PWD/Android/tools/json.jar"
if [[ ! -f "$json_source" ]]; then
  json_source="$PWD/.build/json-20240303.jar"
  curl --fail --location --proto '=https' --tlsv1.2 --output "$json_source" 'https://repo.maven.apache.org/maven2/org/json/json/20240303/json-20240303.jar'
fi
if command -v sha256sum >/dev/null; then digest="$(sha256sum "$json_source")"; else digest="$(shasum -a 256 "$json_source")"; fi
[[ "${digest%% *}" == 3cf6cd6892e32e2b4c1c39e0f52f5248a2f5b37646fdfbb79a66b46b618414ed ]] || { echo 'JSON-java dependency checksum mismatch' >&2; exit 1; }
sources=()
for name in Planner SchedulePreferenceOptimizer SchedulePriorities ScheduleExplanation DailyTaskOrdering CourseTools StudyLoad ScheduleFeasibilitySearch ScheduleHealth WebCourseImport SyncLedger SyncJSON SyncExchange CloudSnapshot; do
  sources+=("Android/src/local/studyplanner/$name.java")
done
"$JDK/bin/javac" --release 11 -encoding UTF-8 -cp "$json_source" -d "$classes" "${sources[@]}" Server/src/local/studyplanner/CloudSyncServer.java
"$JDK/bin/jar" --create --file "$stage/lib/study-planner-server.jar" -C "$classes" .
cp "$json_source" "$stage/lib/json.jar"
cp Server/{README.md,install.sh,start.sh,backup.sh,server.env.example,study-planner-sync.service,JSON-java-LICENSE.txt} "$stage/"
chmod +x "$stage/"*.sh
printf '%s (%s)\n' "$STUDYPLANNER_VERSION" "$STUDYPLANNER_BUILD" > "$stage/VERSION"
COPYFILE_DISABLE=1 tar -czf "$PWD/dist/学习日程-云同步服务端.tar.gz" -C "$stage" .
echo "服务端部署包已生成：$PWD/dist/学习日程-云同步服务端.tar.gz"
