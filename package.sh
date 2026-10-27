#!/bin/zsh
# Snap 打包脚本：编译 release 版 → 生成 dist/Snap-版本号.dmg 和 dist/Snap-版本号.zip
# 只用系统自带的工具（swift、codesign、hdiutil、ditto），不需要安装任何东西。
# 用法：./package.sh
set -euo pipefail
cd "${0:A:h}"

./build.sh release

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
DIST="dist"
DMG="$DIST/Snap-$VERSION.dmg"
ZIP="$DIST/Snap-$VERSION.zip"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

echo "▸ 检查签名"
codesign --verify --strict --verbose=1 build/Snap.app

mkdir -p "$DIST"
rm -f "$DMG" "$ZIP"

echo "▸ 生成 $DMG"
# 磁盘映像里：Snap.app + 指向「应用程序」文件夹的快捷方式（拖进去即安装）+ 说明文档
ditto build/Snap.app "$STAGING/Snap.app"
ln -s /Applications "$STAGING/应用程序"
cp docs/使用说明.md "$STAGING/使用说明.md"
cp docs/卸载说明.md "$STAGING/卸载说明.md"
# 新系统用 diskutil image（hdiutil create 已标记为过时），旧系统退回 hdiutil
if diskutil image create from -h >/dev/null 2>&1; then
  diskutil image create from --format UDZO --volumeName "Snap $VERSION" "$STAGING" "$DMG" >/dev/null; echo
else
  hdiutil create -volname "Snap $VERSION" -srcfolder "$STAGING" -format UDZO -ov "$DMG" >/dev/null
fi

echo "▸ 生成 $ZIP"
# ditto 打包会保留签名和扩展属性（普通 zip 命令可能破坏签名）
ditto -c -k --keepParent build/Snap.app "$ZIP"

echo "✓ 完成"
ls -lh "$DMG" "$ZIP"
