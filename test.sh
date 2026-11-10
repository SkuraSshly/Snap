#!/bin/zsh
# 运行单元测试（Tests/VelosTests，Swift Testing）：几秒完成，不启动 App、不碰屏幕
# 用法：./test.sh [swift test 的其他参数，例如 --filter ScrollStitcher]
set -euo pipefail
cd "${0:A:h}"

# 只装了命令行工具（没有 Xcode）时，Swift Testing 的宏插件放在 plugins/testing 子目录里，SwiftPM 找不到，需要手动指定
EXTRA=()
PLUGINS="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
if [[ -d "$PLUGINS" ]]; then EXTRA=(-Xswiftc -plugin-path -Xswiftc "$PLUGINS"); fi

swift test "${EXTRA[@]}" "$@"
