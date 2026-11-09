# 第三方声明

## 代码和依赖

Velos **没有使用任何第三方库、框架或代码**（`Package.swift` 里没有外部依赖），也没有打包任何第三方字体、图片或声音。
App 只调用 macOS 自带的系统框架，它们属于操作系统，不随 Velos 分发：

| 用途 | 系统框架 |
|---|---|
| 截图、录屏 | ScreenCaptureKit、AVFoundation、Core Graphics、ImageIO |
| 截屏翻译：文字识别、语言判断 | Vision、Natural Language |
| 截屏翻译：Apple 翻译 | Translation |
| 单词查词 | Dictionary Services（「词典」App 里启用的词典） |
| 朗读 | AVFoundation（AVSpeechSynthesizer） |
| 界面、图标 | AppKit、SwiftUI、SF Symbols |
| 翻译引擎的 Key | Security（钥匙串） |
| 在线引擎的请求签名 | CryptoKit |

SF Symbols 按 Apple 的许可只在 Apple 平台的 App 界面里使用。

## 参考

截屏翻译的交互（先弹出结果窗口、再填入识别结果和译文）参考了开源词典 App [Easydict](https://github.com/tisfeng/Easydict)（GPL-3.0）的使用体验。
Velos 只阅读、对比了它的做法（识别参数、窗口先出现），**没有复制或改写它的任何代码**。

## 在线翻译服务

在线翻译引擎默认全部关闭。你启用某个引擎并填写自己的 Key 后，要翻译的文字会发送给那家服务商，使用受该服务商的条款和隐私政策约束：
有道智云、DeepL、微软翻译（Azure AI Translator）、百度翻译开放平台、腾讯云机器翻译、火山引擎机器翻译、
Anthropic（Claude API），以及你在「大模型（OpenAI 兼容）」里填写的服务商。
这些名称和商标属于各自的所有者；Velos 与它们没有关联，也没有得到它们的认可。

Velos 本身以 MIT 许可证发布，见 [LICENSE](LICENSE)。
