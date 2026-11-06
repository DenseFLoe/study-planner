#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash Scripts/prepare-agent-prototype.sh
./Scripts/test.sh --filter AgentPrototypeTests
