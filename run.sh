#!/bin/zsh
# 开发用：编译，然后结束正在运行的 Velos 并重新启动
# 用法：./run.sh [release|debug]
set -euo pipefail
cd "${0:A:h}"

./build.sh "${1:-release}"

# 只结束本项目编译出的 Velos，不误伤其他同名进程
pkill -f "/Velos.app/Contents/MacOS/Velos" 2>/dev/null && sleep 0.5 || true

# 必须用 open 启动：这样 Velos 自己才是权限的「责任进程」，
# 直接在终端里运行二进制的话，系统会把屏幕录制权限算到终端头上
open build/Velos.app
echo "✓ Velos 已启动"
