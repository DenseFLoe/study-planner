#!/usr/bin/env bash
# Exercise the production permission/fallback logic on Linux or macOS without
# AppKit, launching applications, contacting websites, or asking for OS permissions.
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/study-planner-playback.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
export CLANG_MODULE_CACHE_PATH="$test_dir/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$test_dir/swift-module-cache"
mkdir -p "$test_dir/Sources/StudyPlanner" "$test_dir/Tests/StudyPlannerTests"
cp "$repo_dir/Sources/StudyPlanner/PlaybackDetection.swift" "$test_dir/Sources/StudyPlanner/"
cp "$repo_dir/Sources/StudyPlanner/BrowserPlaybackScan.swift" "$test_dir/Sources/StudyPlanner/"
cp "$repo_dir/Tests/StudyPlannerTests/PlaybackDetectionTests.swift" "$test_dir/Tests/StudyPlannerTests/"
cp "$repo_dir/Tests/StudyPlannerTests/BrowserPlaybackScanTests.swift" "$test_dir/Tests/StudyPlannerTests/"
cat > "$test_dir/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "PlaybackRegression", platforms: [.macOS(.v14)], targets: [
    .target(name: "StudyPlanner"),
    .testTarget(name: "StudyPlannerTests", dependencies: ["StudyPlanner"])
])
SWIFT
swift test --disable-sandbox --package-path "$test_dir" \
    --cache-path "$test_dir/cache" --config-path "$test_dir/config" \
    --security-path "$test_dir/security" "$@"
