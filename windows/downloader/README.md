# Windows 下载器

`Velos-Windows-Downloader.exe` 是单文件下载器，使用 Windows 10 2004 及更新系统自带的 .NET Framework 4.8，不随下载器分发 .NET 10。Windows 主程序 ZIP 仍是自包含版本。

下载器本身为 x86 程序，兼容 x64／x86 系统；通过原生系统信息识别操作系统架构，在 64 位系统自动推荐 x64，也可手动选 x86。只提供这两种架构，没有 ARM 构建。

用户选择 ZIP 保存位置后开始下载。下载进度、取消、重试和打开文件夹均在窗口中完成；文件长度及 SHA-256 全部通过后才把临时文件提交为目标文件。取消、网络失败或校验失败不覆盖已有文件。同名文件需要保存对话框确认；下载过程中突然出现的同名文件也不会被静默覆盖。不自动执行下载的程序。

本版下载器绑定 `windows-v3.0.0-preview.20`。发布信息与安装包都从 GitHub Release 获取，不使用 GitHub API，因此不受公共 API 查询配额影响。所有请求和重定向均要求 HTTPS。完整性校验用于发现损坏或文件不一致，不等同于代码签名。

## 构建与检查

在仓库根目录运行：

```powershell
./windows/scripts/Build-Downloader.ps1
$tests = ./windows/scripts/Build-Downloader.ps1 -Tests
& $tests "$env:TEMP/VelosDownloaderTests-UniqueDirectory"
```

测试目录应当是一个新的目录。测试使用假 HTTP 响应和合成字节，不下载或运行真实应用，覆盖架构、清单校验、流式下载、SHA-256、覆盖、取消、临时文件及重定向等边界。

发布顺序：构建并打包主程序，生成 `Velos-Windows.json`，编译下载器，将这些文件及 SHA-256 上传同一 Windows Release。发布版本号来自 `Velos.App.csproj`；每次发布新版本需重新构建下载器及清单。
