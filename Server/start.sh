#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
exec java -Xmx512m -cp 'lib/*' local.studyplanner.CloudSyncServer
