#!/bin/zsh
# Snap 构建脚本：编译 → 组装 Snap.app → 签名
# 用法：./build.sh [release|debug]    默认 release，产物在 build/Snap.app
set -euo pipefail
cd "${0:A:h}"

CONFIG="${1:-release}"
APP_NAME="Snap"
APP="build/$APP_NAME.app"
PLIST="Resources/Info.plist"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$PLIST")"

# 签名身份：默认 ad-hoc（"-"），不需要任何证书。
# 如果你在「钥匙串访问」里创建了自签名代码签名证书，可以：export SNAP_SIGN_IDENTITY="证书名称"
SIGN_IDENTITY="${SNAP_SIGN_IDENTITY:--}"

echo "▸ 编译（$CONFIG）"
# SNAP_OPTIMIZE=1：测试版也开编译优化（测长截图这类性能敏感的功能时用，速度和正式版一致）
EXTRA=()
if [[ "${SNAP_OPTIMIZE:-}" == "1" ]]; then EXTRA=(-Xswiftc -O); fi
swift build -c "$CONFIG" --arch arm64 "${EXTRA[@]}"
BIN_DIR="$(swift build -c "$CONFIG" --arch arm64 "${EXTRA[@]}" --show-bin-path)"

echo "▸ 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "$PLIST" "$APP/Contents/Info.plist"
if [[ "$CONFIG" == "debug" ]]; then
  # 测试版用单独的标识和名字：和正式版互不干扰（登录项不会被测试版抢走，设置也分开存）。
  # 系统权限按标识区分，测试版第一次运行需要单独授予屏幕录制权限（列表里显示「Snap 测试版」）
  BUNDLE_ID="$BUNDLE_ID.debug"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName Snap 测试版" "$APP/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleName string Snap 测试版" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Snap 测试版" "$APP/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string Snap 测试版" "$APP/Contents/Info.plist"
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # 图标（由 scripts/make-icon.swift 生成）
# 截屏翻译的文字识别服务（XPC 服务：按需启动，空闲 30 秒后自动退出）
SERVICE="$APP/Contents/XPCServices/SnapOCR.xpc"
SERVICE_PLIST="Resources/OCRService-Info.plist"
SERVICE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$SERVICE_PLIST")"
mkdir -p "$SERVICE/Contents/MacOS"
cp "$BIN_DIR/SnapOCRService" "$SERVICE/Contents/MacOS/SnapOCR"
cp "$SERVICE_PLIST" "$SERVICE/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "▸ 签名（${SIGN_IDENTITY}）"
# 先签里面的服务，再签整个 App
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --sign - \
    --identifier "$SERVICE_ID" \
    --requirements "=designated => identifier \"$SERVICE_ID\"" \
    "$SERVICE"
  # ad-hoc 签名默认的「指定要求」(designated requirement) 是二进制的 cdhash，
  # 每次重新编译都会变化，系统会把新版本当成另一个 App，屏幕录制权限随之失效。
  # 这里把指定要求显式设为 bundle id，重新编译后已授予的权限依然有效（仅适合本机自用）。
  codesign --force --sign - \
    --identifier "$BUNDLE_ID" \
    --requirements "=designated => identifier \"$BUNDLE_ID\"" \
    "$APP"
else
  codesign --force --sign "$SIGN_IDENTITY" --identifier "$SERVICE_ID" "$SERVICE"
  codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP"
fi

SIZE="$(du -sh "$APP" | cut -f1)"
echo "✓ 完成：$APP（$SIZE）"
