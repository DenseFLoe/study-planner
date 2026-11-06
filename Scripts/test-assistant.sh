#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Synthetic fixtures and intercepted HTTP only. Never loads personal data or credentials.
bash Scripts/prepare-agent-prototype.sh
./Scripts/test.sh --filter 'AssistantTests|AssistantHTTPTests|AgentPrototypeTests'
