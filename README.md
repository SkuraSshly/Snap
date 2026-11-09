<p align="center">
  <img src="docs/images/icon.png" width="144" alt="Velos 图标">
</p>

<h1 align="center">Velos</h1>

<p align="center">
  原生、轻巧的 macOS 截图工具：截图标注、长截图、录屏、截屏翻译<br>
  <sub>下载 2.5 MB · 空闲内存约 13 MB · 默认不联网 · 不收集任何数据 · 没有第三方依赖</sub>
</p>

<p align="center">
  <a href="https://github.com/SkuraSshly/Velos/releases/latest"><b>下载</b></a> ·
  <a href="docs/使用说明.md">使用说明</a> ·
  <a href="docs/更新说明.md">更新说明</a> ·
  <a href="docs/卸载说明.md">卸载说明</a>
</p>

<p align="center">
  <img src="docs/images/screenshot-annotate.png" width="680" alt="截图后在原位标注">
</p>

Velos（βέλος）在希腊语里是「箭」——像箭一样快、准地截下屏幕上的东西。

## 能做什么

| | |
|---|---|
| **截图** <kbd>⌥A</kbd> | 冻结画面后框选，悬停自动识别窗口，放大镜精确到像素。直接在原位标注：矩形、椭圆、箭头、画笔、文字、序号、马赛克、模糊……完成后复制、保存、钉在屏幕上，或打开编辑窗口继续改。 |
| **长截图** | 框选后点工具栏的剪刀按钮，滚动页面，Velos 边滚边拼接；标题栏、输入框只出现一次。也可以「自动滚动」：鼠标移到页面上就一下下往下滚，移开就停。 |
| **录屏** <kbd>⌥S</kbd> | 区域或全屏，系统声音和麦克风混成一条音轨，可暂停；倒计时、点击高亮、导出 GIF。录制中照样能截图、翻译，并一起录进视频。 |
| **截屏翻译** <kbd>⌥D</kbd> | 框选文字，离线识别、用 Apple 翻译离线翻译；单个单词查系统词典。也可以接入自己的翻译服务（腾讯、火山、百度、DeepL、OpenAI 兼容大模型等）。 |

<table>
  <tr>
    <td width="60%"><img src="docs/images/long-capture.png" alt="长截图"><br><sub><b>长截图</b>：在选区里滚动，旁边实时预览拼好的长图</sub></td>
    <td width="40%"><img src="docs/images/translate.png" alt="截屏翻译"><br><sub><b>截屏翻译</b>：松开鼠标就出结果，全部在本机完成</sub></td>
  </tr>
</table>

## 安装

需要 **macOS 15 或更新**、**Apple 芯片**的 Mac。

1. 在 [Releases](https://github.com/SkuraSshly/Velos/releases/latest) 下载 `Velos-2.0.dmg`，把 Velos 拖进「应用程序」。
2. 打开 Velos，按引导打开 **屏幕与系统录音** 权限（必需）。麦克风（录自己的声音）和辅助功能（长截图自动滚动）用到时再开。

> 这个版本没有 Apple 开发者证书签名和公证，第一次打开时 macOS 会拦下。到 **系统设置 › 隐私与安全性**，在页面下方点 **「仍要打开」**，只需一次。
>
> 用过旧版 Snap？Velos 就是改名后的 Snap，第一次打开会自动搬来原来的设置。

快捷键都可以在设置里改，全部快捷键和用法见 [使用说明](docs/使用说明.md)。

## 隐私

- 截图、录屏、文字识别、Apple 翻译、查词都在本机完成，默认不联网。
- 只有你在设置里启用并填了 Key 的翻译服务，才会把要翻译的文字（不是截图）发给那一家。Key 只存在本机钥匙串里。
- 不检查更新、不上报崩溃、没有统计；空闲时不运行任何屏幕采集。

## 从源码构建

只需要 Xcode 命令行工具（`xcode-select --install`），没有任何第三方依赖。

```bash
git clone https://github.com/SkuraSshly/Velos.git
cd Velos
./build.sh            # 生成 build/Velos.app
open build/Velos.app
```

| 命令 | 作用 |
|---|---|
| `./build.sh debug` | 调试版，内含自测（`VELOS_UITEST`、`VELOS_RECTEST`、`VELOS_FEATURETEST`、`VELOS_AUTOSCROLL_E2E` 等环境变量） |
| `./run.sh` | 编译并重新启动 |
| `./package.sh` | 打包成 `dist/Velos-版本号.dmg` 和 `.zip` |

源码在 `Sources/Velos`（按功能分文件夹），文字识别在 `Sources/VelosOCRKit`，由单独的识别服务进程调用。App 图标由 `scripts/make-icon.swift` 用代码绘制。

## 许可证

[MIT](LICENSE)
