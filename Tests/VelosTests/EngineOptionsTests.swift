import Foundation
import Testing
@testable import Velos

/// 翻译引擎的普通配置（Base URL、模型名、地域）存在普通设置里，读的时候不用密码；Key、ID 才存钥匙串。
/// 这里只测普通设置这一边，不碰钥匙串（测试程序每次编译签名都不同，读写钥匙串会弹密码框）
@Suite struct EngineOptionsTests {
    @Test func 哪些字段算普通配置() {
        #expect(EngineOptions.isOption("baseURL") && EngineOptions.isOption("model") && EngineOptions.isOption("region"))
        #expect(!EngineOptions.isOption("apiKey") && !EngineOptions.isOption("secretId") && !EngineOptions.isOption("secretKey"))
        // 每个引擎的机密字段都不算普通配置（一定存钥匙串）
        for engine in EngineID.allCases {
            for field in engine.fields where field.secret {
                #expect(!EngineOptions.isOption(field.key), "\(engine.rawValue).\(field.key)")
            }
        }
    }

    @Test func 写进去能读回来清空后算没填() {
        let account = "unitTest.\(UUID().uuidString).model"
        defer { UserDefaults.standard.removeObject(forKey: "engineOption.\(account)") }
        #expect(!EngineOptions.exists(account) && EngineOptions.get(account) == "")
        EngineOptions.set("  deepseek-chat \n", for: account)
        #expect(EngineOptions.exists(account) && EngineOptions.get(account) == "deepseek-chat")
        EngineOptions.set("", for: account)
        #expect(!EngineOptions.exists(account) && EngineOptions.get(account) == "")
    }
}
