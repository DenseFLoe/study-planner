#!/bin/zsh
# 生成 macOS 安装包：dist/学习日程-macOS-<短SHA>.dmg 及同名 .dmg.sha256。
# 只打包 macOS：不调用 release.sh，不构建 Android，不上传或发布。
# 用法：./Scripts/build-dmg.sh [debug|release]，默认 release。
set -euo pipefail

cd "${0:A:h:h}"

configuration="${1:-release}"
case "$configuration" in
    debug|release) ;;
    *)
        echo "用法：$0 [debug|release]" >&2
        exit 2
        ;;
esac

dist_dir="$PWD/dist"
app="$dist_dir/学习日程.app"

# 复用现有应用构建脚本；生成的 .app 保留在 dist，供其他构建产物继续使用。
"$PWD/Scripts/build-app.sh" "$configuration" "$app"

sha="$(git rev-parse --short HEAD)"
base="学习日程-macOS-$sha"
dmg="$dist_dir/$base.dmg"
checksum="$dmg.sha256"

# 临时目录只用于本次打包，退出时只清理它自己。
staging="$(mktemp -d "${TMPDIR:-/tmp}/study-planner-dmg.XXXXXX")"
trap 'rm -rf "$staging"' EXIT

payload="$staging/payload"
mkdir -p "$payload"
ditto "$app" "$payload/学习日程.app"
ln -s /Applications "$payload/应用程序"

# 签名校验、hdiutil verify 和校验文件生成都通过后才替换 dist 中的目标文件；
# 替换分两次移动完成，移动阶段不具备双文件原子性。
codesign --verify --deep --strict "$app"

staged_dmg="$staging/$base.dmg"
hdiutil create -quiet -volname "学习日程" -srcfolder "$payload" -format UDZO -ov "$staged_dmg"
hdiutil verify "$staged_dmg"

# 校验行只写文件名，便于在 dist 目录内直接执行 shasum -c 校验；
# 先在 staging 内生成，校验命令失败时不会留下新 DMG 与旧校验文件。
(
    cd "$staging"
    shasum -a 256 "$base.dmg" > "$base.dmg.sha256"
)

mv -f "$staged_dmg" "$dmg"
mv -f "$staging/$base.dmg.sha256" "$checksum"

echo "macOS 安装包已生成：$dmg"
echo "SHA-256 校验文件：$checksum"
