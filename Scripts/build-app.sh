#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
configuration="${1:-release}"
python3 Scripts/sign-app.py check
metadata="$(mktemp "${TMPDIR:-/tmp}/study-planner-build.XXXXXX")"
trap 'rm -f "$metadata"' EXIT
python3 Scripts/build-metadata.py capture "$PWD" "$configuration" "$metadata"
source "$PWD/Scripts/version.env"
if [[ "${STUDYPLANNER_AGENT_PROTOTYPE:-0}" == 1 || "${STUDYPLANNER_ASSISTANT:-0}" == 1 ]]; then
    bash Scripts/prepare-agent-prototype.sh
fi
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/study-planner-clang"
export SWIFTPM_MODULECACHE_OVERRIDE="${TMPDIR:-/tmp}/study-planner-swift"
swift build --disable-sandbox -c "$configuration"
app="${2:-$PWD/dist/学习日程.app}"
mkdir -p "$app/Contents/MacOS"
cp ".build/$configuration/StudyPlanner" "$app/Contents/MacOS/StudyPlanner"
# SwiftPM resources must accompany the packaged executable.
for resource in .build/"$configuration"/*.bundle; do
    [[ -d "$resource" ]] || continue
    mkdir -p "$app/Contents/Resources"
    cp -R "$resource" "$app/Contents/Resources/"
done
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>StudyPlanner</string>
<key>CFBundleIdentifier</key><string>local.studyplanner.mac</string>
<key>CFBundleName</key><string>学习日程</string>
<key>CFBundleDisplayName</key><string>学习日程</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$STUDYPLANNER_VERSION</string>
<key>CFBundleVersion</key><string>$STUDYPLANNER_BUILD</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>连接 Android 手机热点，在两台设备间同步学习日程。</string>
<key>NSAppleEventsUsageDescription</key><string>在默认浏览器中读取用户指定网站的课程目录、时长与进度，并读取所选观看软件的播放状态用于学习监督。</string>
<key>NSAudioCaptureUsageDescription</key><string>短暂分析所选软件的音量以判断播放活动，不保存或上传音频。</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
<key>CFBundleLocalizations</key><array><string>zh_CN</string></array>
</dict></plist>
PLIST
mkdir -p "$app/Contents/Resources"
# Remove the previous optional payload when building a regular package.
rm -rf "$app/Contents/Resources/AgentPrototype"
if [[ "${STUDYPLANNER_AGENT_PROTOTYPE:-0}" == 1 || "${STUDYPLANNER_ASSISTANT:-0}" == 1 ]]; then
    ditto "$PWD/.build/agent-prototype/payload" "$app/Contents/Resources/AgentPrototype"
    /usr/libexec/PlistBuddy -c 'Add :StudyPlannerAgentPrototype bool true' "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Add :StudyPlannerAssistant bool true' "$app/Contents/Info.plist"
fi
swift Scripts/make-icon.swift "$PWD/dist/StudyPlanner.iconset"
python3 Scripts/package-icon.py "$PWD/dist/StudyPlanner.iconset" "$app/Contents/Resources/AppIcon.icns"
python3 Scripts/build-metadata.py stamp "$PWD" "$metadata" "$app/Contents/Info.plist"
python3 Scripts/build-credential-service.py "$app"
python3 Scripts/sign-app.py sign "$app"
echo "应用已生成：$app"
