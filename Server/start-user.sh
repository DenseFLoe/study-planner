#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
export MALLOC_ARENA_MAX=2
exec "${STUDY_SYNC_JAVA:-java}" -Xms16m -Xmx96m -XX:+UseSerialGC \
  -XX:ActiveProcessorCount=2 -XX:MaxMetaspaceSize=48m -XX:ReservedCodeCacheSize=24m \
  -XX:MaxDirectMemorySize=8m -Xss512k -cp 'lib/*' local.studyplanner.CloudSyncServer
