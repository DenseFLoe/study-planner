#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
exec "${STUDY_SYNC_JAVA:-java}" -Xms16m -Xmx128m -XX:+UseSerialGC \
  -XX:ActiveProcessorCount=2 -XX:MaxMetaspaceSize=64m -XX:ReservedCodeCacheSize=32m \
  -XX:MaxDirectMemorySize=16m -Xss512k -cp 'lib/*' local.studyplanner.CloudSyncServer
