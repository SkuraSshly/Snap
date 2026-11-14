# Windows 在线安装程序

下载 `Velos-Setup.exe` 后打开，自动识别 x64／x86，立即下载对应的完整 EXE，校验 SHA-256 和 PE 架构后安装。没有 ZIP 保存对话框，也不需要解压或安装 .NET。下载阶段支持取消与重试；安装完成后可直接点「启动 Velos」。安装前若已有 Velos 在运行，需要先从托盘退出。

安装到当前用户 `%LOCALAPPDATA%\Programs\Velos`，添加开始菜单快捷方式和 Windows「已安装的应用」卸载入口，不申请管理员权限、不添加登录启动。程序文件替换和系统入口更新失败时恢复原安装；取消不会创建系统入口。不接管已有其他文件的非空目录，也不跟随链接或重解析点。

卸载先退出程序，在 Windows 设置中卸载 Velos，或运行安装目录中的 `Uninstall.exe`。卸载器会复制到系统临时目录运行，以便移除安装目录中的自身；该临时副本可由系统临时文件清理移除。卸载只删除安装器明确拥有的四个文件、对应开始菜单入口和卸载记录；保留截图、录屏、设置与凭据。仅移除指向本安装目录的 Velos 登录启动值。

安装程序使用 Windows 10 2004 及更新系统自带的 .NET Framework 4.8；主程序为 .NET 10 自包含 EXE。安装器本身编译为 x86，可在 x64 Windows 上识别并安装 x64。没有 ARM 构建。绑定当前项目版本的 Release，只接受同仓库、同版本的 EXE 清单，所有请求和重定向必须为 HTTPS。不查询 GitHub API、不包含账号凭据、不收集遥测。文件尚未签名，SHA-256 用于完整性检查。

```powershell
./windows/scripts/Build-Setup.ps1
$tests = ./windows/scripts/Build-Setup.ps1 -Tests
& $tests "$env:TEMP/VelosSetupTests-UniqueDirectory"
./windows/scripts/Package-Setup.ps1
```

测试使用独立目录、合成 PE 和假 HTTP，覆盖下载、取消、损坏、并发文件、被占用文件、回滚、重装、x64／x86 和卸载保留边界。Windows COM 快捷方式与卸载记录也做实际写入／读取／移除，使用隔离的测试注册表项及目录，不在真实开始菜单或真实安装目录写入。发布网络验收下载真实程序并在隔离目录安装／卸载，不启动主程序、不改动用户现有 Velos。
