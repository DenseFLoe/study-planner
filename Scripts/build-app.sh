#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/study-planner-clang"
export SWIFTPM_MODULECACHE_OVERRIDE="${TMPDIR:-/tmp}/study-planner-swift"
configuration="${1:-release}"
swift build --disable-sandbox -c "$configuration"
app="${2:-$PWD/dist/学习日程.app}"
mkdir -p "$app/Contents/MacOS"
cp ".build/$configuration/StudyPlanner" "$app/Contents/MacOS/StudyPlanner"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>StudyPlanner</string>
<key>CFBundleIdentifier</key><string>local.studyplanner.mac</string>
<key>CFBundleName</key><string>学习日程</string>
<key>CFBundleDisplayName</key><string>学习日程</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.1</string>
<key>CFBundleVersion</key><string>3</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>连接 Android 手机热点，在两台设备间同步学习日程。</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
<key>CFBundleLocalizations</key><array><string>zh_CN</string></array>
</dict></plist>
PLIST
mkdir -p "$app/Contents/Resources"
swift Scripts/make-icon.swift "$PWD/dist/StudyPlanner.iconset"
python3 Scripts/package-icon.py "$PWD/dist/StudyPlanner.iconset" "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$app"
echo "应用已生成：$app"
