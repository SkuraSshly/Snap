#!/bin/zsh
# Velos 构建脚本：编译 → 组装 Velos.app → 签名
# 用法：./build.sh [release|debug]    默认 release，产物在 build/Velos.app
set -euo pipefail
cd "${0:A:h}"

CONFIG="${1:-release}"
APP_NAME="Velos"
APP="build/$APP_NAME.app"
PLIST="Resources/Info.plist"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$PLIST")"

# 签名身份：默认 ad-hoc（"-"），不需要任何证书。
# 如果你在「钥匙串访问」里创建了自签名代码签名证书，可以：export VELOS_SIGN_IDENTITY="证书名称"
SIGN_IDENTITY="${VELOS_SIGN_IDENTITY:--}"

echo "▸ 编译（$CONFIG）"
# VELOS_OPTIMIZE=1：测试版也开编译优化（测长截图这类性能敏感的功能时用，速度和正式版一致）
EXTRA=()
if [[ "${VELOS_OPTIMIZE:-}" == "1" ]]; then EXTRA=(-Xswiftc -O); fi
swift build -c "$CONFIG" --arch arm64 "${EXTRA[@]}"
BIN_DIR="$(swift build -c "$CONFIG" --arch arm64 "${EXTRA[@]}" --show-bin-path)"

echo "▸ 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "$PLIST" "$APP/Contents/Info.plist"
if [[ "$CONFIG" == "debug" ]]; then
  # 测试版用单独的标识和名字：和正式版互不干扰（登录项不会被测试版抢走，设置也分开存）。
  # 系统权限按标识区分，测试版第一次运行需要单独授予屏幕录制权限（列表里显示「Velos 测试版」）
  BUNDLE_ID="$BUNDLE_ID.debug"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName Velos 测试版" "$APP/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleName string Velos 测试版" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Velos 测试版" "$APP/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string Velos 测试版" "$APP/Contents/Info.plist"
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # 图标（由 scripts/make-icon.swift 生成）
# 截屏翻译的文字识别服务（XPC 服务：按需启动，空闲 30 秒后自动退出）
SERVICE="$APP/Contents/XPCServices/VelosOCR.xpc"
SERVICE_PLIST="Resources/OCRService-Info.plist"
SERVICE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$SERVICE_PLIST")"
mkdir -p "$SERVICE/Contents/MacOS"
cp "$BIN_DIR/VelosOCRService" "$SERVICE/Contents/MacOS/VelosOCR"
cp "$SERVICE_PLIST" "$SERVICE/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
# 设置窗口（VelosSettings：打开设置时由 Velos 作为子进程启动，关掉窗口 30 秒后自己退出，释放界面框架占的内存）。
# 和 Velos 是同一份程序，用自己的名字和标识打包：活动监视器里显示 VelosSettings，和 VelosOCR 一样
SETTINGS_APP="$APP/Contents/Helpers/VelosSettings.app"
SETTINGS_ID="$BUNDLE_ID.settings"
mkdir -p "$SETTINGS_APP/Contents/MacOS" "$SETTINGS_APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$SETTINGS_APP/Contents/MacOS/VelosSettings"
cp "$APP/Contents/Info.plist" "$SETTINGS_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $SETTINGS_ID" \
  -c "Set :CFBundleExecutable VelosSettings" \
  -c "Set :CFBundleName VelosSettings" \
  -c "Set :CFBundleDisplayName VelosSettings" "$SETTINGS_APP/Contents/Info.plist"
# VelosSettings 只带小图标（活动监视器里显示 16–32 像素就够，省下 1.7 MB）；
# 大图标（权限引导里的）启动时从 Velos.app 读，见 SettingsProcessController
ICON_TMP="$(mktemp -d)"
iconutil -c iconset Resources/AppIcon.icns -o "$ICON_TMP/AppIcon.iconset"
find "$ICON_TMP/AppIcon.iconset" -type f ! -name 'icon_16x16*' ! -name 'icon_32x32*' -delete
iconutil -c icns "$ICON_TMP/AppIcon.iconset" -o "$SETTINGS_APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICON_TMP"
printf 'APPL????' > "$SETTINGS_APP/Contents/PkgInfo"

if [[ "$CONFIG" == "release" ]]; then
  # 正式版去掉调试符号（只在开发时读崩溃日志有用）：程序文件小一半，Velos 和 VelosSettings 各一份都变小
  strip -x "$APP/Contents/MacOS/$APP_NAME" "$SETTINGS_APP/Contents/MacOS/VelosSettings" "$SERVICE/Contents/MacOS/VelosOCR"
fi

# VelosSettings 那份程序换一个自己的 UUID：和 Velos 一模一样的话，系统日志会把两个进程的名字弄混
swift scripts/set-uuid.swift "$SETTINGS_APP/Contents/MacOS/VelosSettings" VelosSettings >/dev/null

echo "▸ 签名（${SIGN_IDENTITY}）"
# 先签里面的服务和设置窗口，再签整个 App
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --sign - \
    --identifier "$SERVICE_ID" \
    --requirements "=designated => identifier \"$SERVICE_ID\"" \
    "$SERVICE"
  codesign --force --sign - \
    --identifier "$SETTINGS_ID" \
    --requirements "=designated => identifier \"$SETTINGS_ID\"" \
    "$SETTINGS_APP"
  # ad-hoc 签名默认的「指定要求」(designated requirement) 是二进制的 cdhash，
  # 每次重新编译都会变化，系统会把新版本当成另一个 App，屏幕录制权限随之失效。
  # 这里把指定要求显式设为 bundle id，重新编译后已授予的权限依然有效（仅适合本机自用）。
  codesign --force --sign - \
    --identifier "$BUNDLE_ID" \
    --requirements "=designated => identifier \"$BUNDLE_ID\"" \
    "$APP"
else
  codesign --force --sign "$SIGN_IDENTITY" --identifier "$SERVICE_ID" "$SERVICE"
  codesign --force --sign "$SIGN_IDENTITY" --identifier "$SETTINGS_ID" "$SETTINGS_APP"
  codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP"
fi

SIZE="$(du -sh "$APP" | cut -f1)"
echo "✓ 完成：$APP（$SIZE）"
