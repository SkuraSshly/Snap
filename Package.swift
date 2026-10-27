// swift-tools-version: 6.0
// Snap —— macOS 原生截图 + 录屏工具
// 只依赖系统框架（AppKit / SwiftUI / ScreenCaptureKit / AVFoundation 等），没有任何第三方依赖。
// 用 SwiftPM 编译出可执行文件，再由 build.sh 组装成 Snap.app 并签名。

import PackageDescription

let package = Package(
    name: "Snap",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Snap",
            path: "Sources/Snap"
        )
    ],
    // 使用 Swift 5 语言模式：AppKit / AVFoundation 回调较多，Swift 6 严格并发检查会带来大量样板代码
    swiftLanguageModes: [.v5]
)
