#!/usr/bin/env bash
# CI 入口：准备 JSON-java 依赖后，按依赖顺序生成 fixture 并运行全部测试，
# 最后核对 Swift 与 Java 云端快照的双向兼容性。只读取仓库，不提交任何产物。
set -euo pipefail
cd "$(dirname "$0")/.."

# Fast packaging/dependency checks run before toolchain builds or downloads.
python3 Scripts/test-build-metadata.py
python3 Scripts/test-json-bootstrap.py
node Android/tests/crawlers.test.js
bash Android/check-api.sh

bash Scripts/prepare-json-java.sh

# 跨语言 fixture 共用同一个临时目录，退出时清理。
fixture="$(mktemp -d "${TMPDIR:-/tmp}/study-cloud-wire.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
export STUDY_CLOUD_FIXTURE_DIR="$fixture"

# 1. 服务端测试，并写出 Java 生成的云端快照 fixture。
./Server/test.sh

# 2. 先生成 Android 往返测试需要的 Swift fixture，避免依赖本机旧文件。
./Scripts/test.sh --filter 'SyncLedgerTests/test(WireFixtureAndJavaResponse|ConfirmationWireRoundTrip)|FloatingEventTests/testSyncPreservesFloatingFields|AppReviewRegressionTests/testOfflineConfirmationsSurviveMergeRegardlessOfTaskWinnerOrDraftDeletion'

# 3. Android 测试（需要 JDK 11 与 Node 22）。
./Android/test.sh

# 4. Java 读取 Swift fixture，写回确认、浮动事项和同步记录的响应。
JDK="${JAVA_HOME:-$(/usr/libexec/java_home -v 11)}"
"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/SyncTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.SyncTests

# 5. 所有跨语言 fixture 已就绪，再运行完整 Swift 测试。
# CloudArchiveTests 读取 Java 云端快照并写出 Swift 云端快照。
./Scripts/test.sh

# 6. Java 侧校验 Swift 快照可完整还原。
"$JDK/bin/java" -cp '.build/cloud-server-package/lib/*:.build/cloud-server-tests' local.studyplanner.CloudWireCheck "$STUDY_CLOUD_FIXTURE_DIR/swift-latest.json.gz"
