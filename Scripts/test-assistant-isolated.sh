#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# No app entry point, production database, keychain call or external request.
# The one existing persistent UserDefaults test is deliberately excluded.
assistant_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/study-assistant-tests.XXXXXX")
echo "Isolated test package and logs: $assistant_test_dir"
python3 - "$assistant_test_dir" <<'PY'
from pathlib import Path
import hashlib
import json
import shutil
import sys

target = Path(sys.argv[1])
files = list(Path("Sources/StudyCore").glob("*.swift"))
files += [Path("Sources/StudyPlanner") / name for name in ("AssistantAPI.swift", "AssistantSession.swift")]
files += list(Path("Tests/StudyCoreTests").glob("Assistant*.swift"))
files += list(Path("Tests/StudyPlannerTests").glob("Assistant*.swift"))
files += [Path("Tests/StudyCoreTests") / name for name in (
    "ScheduleEngineTests.swift", "ScheduleExplanationTests.swift", "ScheduleRestConflictTests.swift",
    "ScheduleHealthTests.swift", "SchedulePreferenceTests.swift", "SavedScheduleIntegrityTests.swift",
    "DailyConsequenceTests.swift", "DailyConsequenceSumTests.swift", "DailyConsequenceTargetTests.swift",
    "WeeklyStudyReportTests.swift", "WeeklyActualStudySeriesTests.swift")]
hashes = {}
for source in files:
    destination = target / source
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)
    hashes[str(source)] = hashlib.sha256(source.read_bytes()).hexdigest()
(target / "source-hashes.json").write_text(json.dumps(hashes, sort_keys=True, indent=2))
(target / "Package.swift").write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "AssistantIsolated", platforms: [.macOS(.v14)], targets: [
    .target(name: "StudyCore"),
    .target(name: "StudyPlanner", dependencies: ["StudyCore"]),
    .testTarget(name: "StudyCoreTests", dependencies: ["StudyCore"]),
    .testTarget(name: "StudyPlannerTests", dependencies: ["StudyPlanner", "StudyCore"])
])
''')
PY

export CLANG_MODULE_CACHE_PATH="$assistant_test_dir/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$assistant_test_dir/swift-cache"
swift test --disable-sandbox --package-path "$assistant_test_dir" \
    --skip 'AssistantSessionTests.testConfigurationPersistenceContainsNoKeyQuestionAnswerOrData' "$@" \
    2>&1 | tee "$assistant_test_dir/tests.log"

python3 - "$assistant_test_dir" <<'PY'
from pathlib import Path
import hashlib
import json
import sys

target = Path(sys.argv[1])
for path, expected in json.loads((target / "source-hashes.json").read_text()).items():
    for source in (Path(path), target / path):
        assert hashlib.sha256(source.read_bytes()).hexdigest() == expected, f"Changed during test: {source}"
print("Verified: tested copies match unchanged repository source and tests.")
PY
