#!/usr/bin/env bash
# CI 入口：准备 JSON-java 依赖后，按顺序运行服务端、Swift、Android 测试，
# 最后核对 Swift 与 Java 云端快照的双向兼容性。只读取仓库，不提交任何产物。
set -euo pipefail
cd "$(dirname "$0")/.."

json_jar="Android/tools/json.jar"
json_url='https://repo.maven.apache.org/maven2/org/json/json/20240303/json-20240303.jar'
json_sha256='3cf6cd6892e32e2b4c1c39e0f52f5248a2f5b37646fdfbb79a66b46b618414ed'

# Android/tools 不入库，缺失时从官方 Maven 下载，再用固定 SHA256 校验。
if [[ ! -f "$json_jar" ]]; then
  mkdir -p "$(dirname "$json_jar")"
  curl --fail --location --proto '=https' --tlsv1.2 --output "$json_jar" "$json_url"
fi
if command -v sha256sum >/dev/null; then digest="$(sha256sum "$json_jar")"; else digest="$(shasum -a 256 "$json_jar")"; fi
[[ "${digest%% *}" == "$json_sha256" ]] || { echo 'JSON-java dependency checksum mismatch' >&2; exit 1; }

# 跨语言 fixture 共用同一个临时目录，退出时清理。
fixture="$(mktemp -d "${TMPDIR:-/tmp}/study-cloud-wire.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
export STUDY_CLOUD_FIXTURE_DIR="$fixture"

# 1. 服务端测试，并写出 Java 生成的云端快照 fixture。
./Server/test.sh

# 2. 全部 Swift 测试；CloudArchiveTests 读取 Java fixture 并写出 Swift fixture。
./Scripts/test.sh

# 3. Android 测试（需要 JDK 11 与 Node 22）。
./Android/test.sh

# 4. 复跑云端兼容性相关 Swift 用例，确认完整流程后 fixture 依旧一致。
./Scripts/test.sh --filter 'AndroidParityTests|AppReviewRegressionTests/testMergedConfirmationJavaRoundTrip|CloudArchiveTests/testJavaFullSnapshotCompatibility'

# 5. Java 侧校验 Swift 快照可完整还原。
java -cp '.build/cloud-server-package/lib/*:.build/cloud-server-tests' local.studyplanner.CloudWireCheck "$STUDY_CLOUD_FIXTURE_DIR/swift-latest.json.gz"
