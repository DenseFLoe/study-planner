#!/usr/bin/env bash
# Linux integration: fresh Swift fixtures -> Java checks/replies -> full Swift -> Java cloud archive.
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p .build
# Keep this relative: host and container have different repository mount paths.
portable_fixture="$(mktemp -d .build/portable-wire.XXXXXX)"
trap 'rm -rf -- "$portable_fixture"' EXIT
export STUDY_CLOUD_FIXTURE_DIR="$portable_fixture"
swift_image='swift@sha256:95f6ef898992dc840b35517e780f6f6db9661432775ab0b33cc0a531ea749bdb'
swift_tests() {
  docker run --rm --volume "$PWD:/workspace" --workdir /workspace \
    --env STUDY_CLOUD_FIXTURE_DIR "$swift_image" swift test --jobs 2 "$@"
}
require_fixtures() {
  for fixture_name in "$@"; do
    if [[ ! -s "$portable_fixture/$fixture_name" ]]; then
      echo "Missing cross-language fixture: $fixture_name" >&2
      exit 1
    fi
  done
}

swift_tests --filter 'SyncLedgerTests/test(WireFixtureAndJavaResponse|ConfirmationWireRoundTrip)|FloatingEventTests/testSyncPreservesFloatingFields|AppReviewRegressionTests/testOfflineConfirmationsSurviveMergeRegardlessOfTaskWinnerOrDraftDeletion'
require_fixtures study-sync-swift-fixture.json study-confirmation-swift-fixture.json \
  study-floating-swift-fixture.json study-merge-regression-swift.json swift-file-backup.json

bash Scripts/test-java-ci.sh
JDK="${JAVA_HOME:-$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")}"
"$JDK/bin/javac" -cp Android/tools/json.jar:Android/build/tests -d Android/build/tests Android/tests/SyncTests.java
"$JDK/bin/java" -cp Android/tools/json.jar:Android/build/tests local.studyplanner.SyncTests
require_fixtures study-sync-java-fixture.json study-confirmation-java-fixture.json \
  study-floating-java-fixture.json study-merge-regression-java.json android-file-backup.json java-latest.json.gz

swift_tests
require_fixtures swift-latest.json.gz
"$JDK/bin/java" -cp '.build/cloud-server-package/lib/*:.build/cloud-server-tests' \
  local.studyplanner.CloudWireCheck "$portable_fixture/swift-latest.json.gz"
