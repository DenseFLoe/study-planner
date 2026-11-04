#!/usr/bin/env bash
# Independent checks that do not need Xcode or Swift-generated compatibility fixtures.
# The macOS CI entry still runs the complete bidirectional Swift/Java checks.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 Scripts/test-build-metadata.py
bash Android/check-api.sh

bash Scripts/prepare-json-java.sh

bash Server/test.sh
bash Android/test.sh
