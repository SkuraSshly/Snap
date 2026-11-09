// swift-tools-version: 6.0
// Velos —— macOS 原生截图 + 录屏工具
// 只依赖系统框架（AppKit / SwiftUI / ScreenCaptureKit / AVFoundation 等），没有任何第三方依赖。
// 用 SwiftPM 编译出可执行文件，再由 build.sh 组装成 Velos.app 并签名。

import PackageDescription

let package = Package(
    name: "Velos",
    platforms: [.macOS(.v15)],
    targets: [
        // 截屏翻译的文字识别（Vision）和语言检测；Velos 和识别服务进程共用
        .target(
            name: "VelosOCRKit",
            path: "Sources/VelosOCRKit"
        ),
        .executableTarget(
            name: "Velos",
            dependencies: ["VelosOCRKit"],
            path: "Sources/Velos"
        ),
        // 识别服务进程（XPC 服务，由 build.sh 放进 Velos.app/Contents/XPCServices/VelosOCR.xpc）
        .executableTarget(
            name: "VelosOCRService",
            dependencies: ["VelosOCRKit"],
            path: "Sources/VelosOCRService"
        ),
    ],
    // 使用 Swift 5 语言模式：AppKit / AVFoundation 回调较多，Swift 6 严格并发检查会带来大量样板代码
    swiftLanguageModes: [.v5]
)
