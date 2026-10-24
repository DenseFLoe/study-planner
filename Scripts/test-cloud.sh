#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
fixture="$(mktemp -d "${TMPDIR:-/tmp}/study-cloud-wire.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
export STUDY_CLOUD_FIXTURE_DIR="$fixture"
./Server/test.sh
./Scripts/test.sh --filter 'CloudArchiveTests|CloudSyncClientTests'
if [[ "$(uname -s)" == Darwin ]]; then JDK="$(/usr/libexec/java_home -v 11)"; else JDK="${JAVA_HOME:-$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")}"; fi
"$JDK/bin/java" -cp '.build/cloud-server-package/lib/*:.build/cloud-server-tests' local.studyplanner.CloudWireCheck "$fixture/swift-latest.json.gz"
