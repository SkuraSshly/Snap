// 给 VelosSettings 那份程序换一个自己的 UUID（build.sh 在签名前调用）。
//
// VelosSettings 是 Velos 程序的一份拷贝，两份的 UUID（程序的身份编号，只用于调试和日志）一模一样，
// 系统日志按 UUID 找进程名时会把两者弄混（Velos 的日志显示成 VelosSettings）。
// 这里把拷贝里的 UUID 改成由原 UUID 和一个标签算出来的新值（每次打包结果一样），不影响程序运行。
//
// 用法：swift scripts/set-uuid.swift <程序文件> <标签>
import CryptoKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("用法：swift set-uuid.swift <程序文件> <标签>\n".utf8))
    exit(1)
}
let url = URL(fileURLWithPath: arguments[1])
var data = try Data(contentsOf: url)

func read32(_ offset: Int) -> UInt32 {
    data.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
}

// 只处理 64 位、单一架构的 Mach-O（Velos 只编 arm64）
guard read32(0) == 0xFEED_FACF else {
    FileHandle.standardError.write(Data("不是 64 位 Mach-O 程序：\(url.path)\n".utf8))
    exit(1)
}
let commandCount = Int(read32(16))
var offset = 32   // mach_header_64 的大小
let lcUUID: UInt32 = 0x1B
for _ in 0..<commandCount {
    let command = read32(offset), size = Int(read32(offset + 4))
    if command == lcUUID {
        let old = data.subdata(in: offset + 8..<offset + 24)
        var new = Array(SHA256.hash(data: old + Data(arguments[2].utf8)).prefix(16))
        new[6] = (new[6] & 0x0F) | 0x40   // 标成版本 4 的 UUID
        new[8] = (new[8] & 0x3F) | 0x80
        data.replaceSubrange(offset + 8..<offset + 24, with: new)
        try data.write(to: url)
        print("UUID 已更新：\(UUID(uuid: (new[0], new[1], new[2], new[3], new[4], new[5], new[6], new[7], new[8], new[9], new[10], new[11], new[12], new[13], new[14], new[15]))))")
        exit(0)
    }
    offset += size
}
FileHandle.standardError.write(Data("没找到 UUID：\(url.path)\n".utf8))
exit(1)
