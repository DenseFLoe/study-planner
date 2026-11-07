#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Synthetic fixtures and intercepted HTTP only. Never loads personal data or credentials.
./Scripts/test.sh --filter 'Assistant.*Tests'
