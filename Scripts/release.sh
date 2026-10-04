#!/bin/zsh
set -euo pipefail

cd "${0:A:h:h}"

source "$PWD/Scripts/version.env"
version="$STUDYPLANNER_VERSION"
dist_dir="$PWD/dist"
app="$dist_dir/学习日程.app"
apk="$dist_dir/StudyPlanner-Android-v$version.apk"
dmg="$dist_dir/StudyPlanner-macOS-AppleSilicon-v$version.dmg"
release_dir="$dist_dir/StudyPlanner-v$version"
archive="$dist_dir/StudyPlanner-v$version-release.zip"

rm -rf "$app" "$release_dir" "$dmg" "$archive" "$archive.sha256" "$dist_dir/StudyPlanner.iconset"
rm -f "$apk" "$apk.idsig"
rm -rf "$dist_dir/学习日程-v$version"
rm -f "$dist_dir/学习日程-Android.apk" "$dist_dir/学习日程-macOS-Apple芯片.dmg" "$dist_dir/学习日程-v$version-发布包.zip" "$dist_dir/学习日程-v$version-发布包.zip.sha256"
rm -f "$dist_dir/学习日程-安卓版.apk" "$dist_dir/学习日程-安卓版.apk.sha256" "$dist_dir/安卓版安装说明.txt"
mkdir -p "$dist_dir"

"$PWD/Scripts/build-app.sh" release "$app"

STUDYPLANNER_APK_OUTPUT="$apk" "$PWD/Android/build.sh"
rm -f "$apk.idsig"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/study-planner-release.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
mkdir -p "$work_dir/dmg"
ditto "$app" "$work_dir/dmg/学习日程.app"
ln -s /Applications "$work_dir/dmg/应用程序"
hdiutil create -quiet -volname "学习日程" -srcfolder "$work_dir/dmg" -ov -format UDZO "$dmg"

mkdir -p "$release_dir"
cp "$dmg" "$apk" "$release_dir/"

cat > "$release_dir/INSTALL-zh-CN.txt" <<EOF
学习日程 v$version

macOS（macOS 14 或更高版本，仅支持 Apple 芯片）
1. 打开“StudyPlanner-macOS-AppleSilicon-v$version.dmg”。
2. 把“学习日程”拖入“应用程序”。
3. 本版本没有 Apple Developer ID 公证。首次启动时，请在 Finder 中右键应用并选择“打开”，再确认打开。

Android（Android 8.0 或更高版本）
1. 把“StudyPlanner-Android-v$version.apk”传到手机并打开。
2. 按系统提示允许当前文件管理器安装未知应用，然后完成安装。
3. 如已安装 1.2：旧版签名与本版不同。请先在旧版的“设置 → 数据与备份”导出 JSON，卸载旧版，再安装本版并恢复备份。

数据与同步
- 安装包不含个人课程、日程、备份或配对凭据，首次打开为空白日程。
- 手机开热点、Mac 连接热点后，可由 Mac 生成一次性二维码，并由 Android 扫码完成局域网配对和同步。
- 请妥善保存自己的应用内 JSON 备份；卸载 Android 应用或清除其数据会删除本机记录。

完整源码与说明：https://github.com/DenseFLoe/study-planner
EOF

(
  cd "$release_dir"
  shasum -a 256 "${dmg:t}" "${apk:t}" > SHA256SUMS.txt
)

(
  cd "$dist_dir"
  /usr/bin/zip -q -r -X "${archive:t}" "${release_dir:t}"
  shasum -a 256 "${archive:t}" > "${archive:t}.sha256"
)

rm -rf "$app" "$dist_dir/StudyPlanner.iconset"

echo "发布物已生成："
echo "  $dmg"
echo "  $apk"
echo "  $archive"
