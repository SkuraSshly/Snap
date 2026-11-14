using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace Velos.Setup
{
    internal static class SetupTests
    {
        private static int passed;
        private static string root;
        [STAThread] private static int Main(string[] args)
        {
            root = Path.GetFullPath(args.Length > 0 ? args[0] : Path.Combine(Path.GetTempPath(), "VelosSetupTests", Guid.NewGuid().ToString("N")));
            Directory.CreateDirectory(root);
            System.Net.ServicePointManager.SecurityProtocol = System.Net.SecurityProtocolType.Tls12;
            try { Run().GetAwaiter().GetResult(); if (args.Length > 1 && args[1] == "--published") PublishedChecks().GetAwaiter().GetResult(); Console.WriteLine("通过 " + passed + "/" + passed); return 0; }
            catch (Exception error) { Console.WriteLine("失败 " + error); return 1; }
        }
        private static void Check(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); passed++; Console.WriteLine("通过 " + message); }
        private static ReleaseAsset Asset(byte[] bytes)
        {
            using (var hash = SHA256.Create()) return new ReleaseAsset { name = "Velos-" + BuildInfo.Version + "-win-x64.exe", url = BuildInfo.DownloadRoot + "Velos-" + BuildInfo.Version + "-win-x64.exe", size = bytes.Length, sha256 = DownloadClient.Hex(hash.ComputeHash(bytes)) };
        }
        private static HttpResponseMessage Bytes(byte[] bytes) { return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(bytes) }; }
        private static byte[] Executable(string architecture, byte marker)
        {
            var bytes = new byte[512]; bytes[0] = 0x4d; bytes[1] = 0x5a; bytes[60] = 64;
            bytes[64] = 0x50; bytes[65] = 0x45; bytes[68] = architecture == "x64" ? (byte)0x64 : (byte)0x4c; bytes[69] = architecture == "x64" ? (byte)0x86 : (byte)0x01;
            bytes[100] = marker; return bytes;
        }
        private static DownloadClient Client(byte[] bytes) { return new DownloadClient(new Handler(delegate { return Task.FromResult(Bytes(bytes)); })); }
        private static async Task InstallationChecks()
        {
            var installRoot = Path.Combine(root, "安装 测试"); var integration = new FakeIntegration();
            var installation = new Installation(installRoot, integration); var first = Executable("x64", 1); var second = Executable("x64", 2);
            var setup = System.Reflection.Assembly.GetExecutingAssembly().Location;
            using (var client = Client(first)) await installation.InstallAsync(client, Asset(first), "x64", setup, "license", null, null, CancellationToken.None);
            Check(File.Exists(installation.ApplicationPath) && File.Exists(Path.Combine(installRoot, "Uninstall.exe")) && integration.Version == BuildInfo.Version,
                "自动下载后安装 EXE、卸载程序与许可证，不生成 ZIP");
            Check(File.ReadAllBytes(installation.ApplicationPath)[100] == 1 && Directory.GetDirectories(installRoot).Length == 0, "中文含空格路径安装完成且清理暂存目录");
            integration.Fail = true;
            using (var client = Client(second))
            {
                try { await installation.InstallAsync(client, Asset(second), "x64", setup, "new license", null, null, CancellationToken.None); throw new Exception("未触发集成失败"); }
                catch (IOException) { Check(File.ReadAllBytes(installation.ApplicationPath)[100] == 1 && File.ReadAllText(Path.Combine(installRoot, "LICENSE.txt")) == "license" && integration.Restored,
                    "快捷方式或注册失败时恢复原程序、许可证和安装记录"); }
            }
            integration.Fail = false;
            using (var locked = File.Open(installation.ApplicationPath, FileMode.Open, FileAccess.Read, FileShare.Read))
            using (var client = Client(second))
            {
                try { await installation.InstallAsync(client, Asset(second), "x64", setup, "new", null, null, CancellationToken.None); throw new Exception("覆盖了被占用文件"); }
                catch (IOException) { Check(File.ReadAllBytes(installation.ApplicationPath)[100] == 1, "原程序被占用时升级失败且保留原安装"); }
                try { installation.Uninstall(); throw new Exception("卸载了被占用文件"); }
                catch (IOException) { Check(!integration.Removed && File.Exists(Path.Combine(installRoot, "install.json")), "被占用时卸载不移除入口与安装记录"); }
            }
            using (var client = Client(second)) await installation.InstallAsync(client, Asset(second), "x64", setup, "new license", null, null, CancellationToken.None);
            Check(File.ReadAllBytes(installation.ApplicationPath)[100] == 2, "重复安装或升级可原位更新");
            var x86 = Executable("x86", 3);
            using (var client = Client(x86))
            {
                try { await installation.InstallAsync(client, Asset(x86), "x64", setup, "", null, null, CancellationToken.None); throw new Exception("安装了错误架构"); }
                catch (InvalidDataException) { Check(File.ReadAllBytes(installation.ApplicationPath)[100] == 2, "校验通过但 PE 架构不匹配也拒绝安装"); }
            }
            var invalid = Asset(second); invalid.sha256 = new string('0', 64);
            using (var client = Client(second))
            {
                try { await installation.InstallAsync(client, invalid, "x64", setup, "", null, null, CancellationToken.None); throw new Exception("安装了错误哈希"); }
                catch (InvalidDataException) { Check(File.ReadAllBytes(installation.ApplicationPath)[100] == 2, "下载校验失败不改变已安装版本"); }
            }
            File.WriteAllText(Path.Combine(installRoot, "user-picture.txt"), "keep");
            installation.Uninstall();
            Check(integration.Removed && !File.Exists(installation.ApplicationPath) && File.ReadAllText(Path.Combine(installRoot, "user-picture.txt")) == "keep",
                "卸载只移除安装器拥有的文件，保留其他用户文件");
            var foreign = Path.Combine(root, "foreign"); Directory.CreateDirectory(foreign); File.WriteAllText(Path.Combine(foreign, "Velos.exe"), "user file");
            using (var client = Client(first))
            {
                try { await new Installation(foreign, new FakeIntegration()).InstallAsync(client, Asset(first), "x64", setup, "", null, null, CancellationToken.None); throw new Exception("覆盖了其他目录"); }
                catch (IOException) { Check(File.ReadAllText(Path.Combine(foreign, "Velos.exe")) == "user file", "不接管没有安装记录的非空目录"); }
            }
            using (var cancellation = new CancellationTokenSource())
            using (var client = new DownloadClient(new Handler(delegate { return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StreamContent(new SlowStream()) }); })))
            {
                cancellation.CancelAfter(50); var canceled = Path.Combine(root, "canceled-install"); var hooks = new FakeIntegration();
                try { await new Installation(canceled, hooks).InstallAsync(client, Asset(new byte[200]), "x64", setup, "", null, null, cancellation.Token); throw new Exception("未取消安装"); }
                catch (OperationCanceledException) { Check(!Directory.Exists(canceled) && hooks.Version == null, "取消自动安装清理暂存且不创建系统入口"); }
            }
            var raceRoot = Path.Combine(root, "installation-race");
            using (var client = new DownloadClient(new Handler(delegate { File.WriteAllText(Path.Combine(raceRoot, "Velos.exe"), "other file"); return Task.FromResult(Bytes(first)); })))
            {
                try { await new Installation(raceRoot, new FakeIntegration()).InstallAsync(client, Asset(first), "x64", setup, "", null, null, CancellationToken.None); throw new Exception("覆盖了并发文件"); }
                catch (IOException) { Check(File.ReadAllText(Path.Combine(raceRoot, "Velos.exe")) == "other file", "安装期间出现同名外部文件也不会覆盖"); }
            }
            var realRoot = Path.Combine(root, "real-shell"); var link = Path.Combine(root, "test-start-menu", "Velos.lnk");
            var keyName = @"Software\Velos.SetupTests\" + Guid.NewGuid().ToString("N");
            var windows = new WindowsIntegration(realRoot, keyName, link); var real = new Installation(realRoot, windows);
            try
            {
                using (var client = Client(x86)) await real.InstallAsync(client, Asset(x86), "x86", setup, "license", null, null, CancellationToken.None);
                using (var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(keyName))
                    Check(key != null && (string)key.GetValue("UninstallString") == "\"" + Path.Combine(realRoot, "Uninstall.exe") + "\" /uninstall" && Shortcut.Target(link) == real.ApplicationPath,
                        "真实 Windows COM 快捷方式和隔离卸载注册表记录正确");
                var snapshot = windows.Capture(); windows.Register(realRoot, "changed", 512); windows.Restore(snapshot);
                using (var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(keyName))
                    Check((string)key.GetValue("DisplayVersion") == BuildInfo.Version && Shortcut.Target(link) == real.ApplicationPath, "真实系统入口快照可恢复");
                real.Uninstall();
                using (var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(keyName))
                    Check(key == null && !File.Exists(link) && !Directory.Exists(realRoot), "真实卸载移除程序、快捷方式和隔离注册表记录");
            }
            finally { Microsoft.Win32.Registry.CurrentUser.DeleteSubKey(keyName, false); }
        }
        private sealed class FakeIntegration : IInstallationIntegration
        {
            internal string Version; internal bool Fail, Restored, Removed;
            public object Capture() { return Version; }
            public void Register(string directory, string version, long bytes) { Version = version; if (Fail) throw new IOException("synthetic integration failure"); }
            public void Restore(object value) { Version = (string)value; Restored = true; }
            public void Remove(string directory) { Removed = true; Version = null; }
        }
        private static async Task PublishedChecks()
        {
            using (var client = new DownloadClient())
            {
                var manifest = await client.LoadAsync(CancellationToken.None);
                foreach (var architecture in new[] { "x64", "x86" })
                {
                    var directory = Path.Combine(root, "published-" + architecture);
                    var key = @"Software\Velos.SetupTests\" + Guid.NewGuid().ToString("N");
                    var link = Path.Combine(root, "published-links", architecture + ".lnk");
                    var integration = new WindowsIntegration(directory, key, link); var install = new Installation(directory, integration);
                    try
                    {
                        await install.InstallAsync(client, manifest.Asset(architecture), architecture,
                            Path.Combine(Path.GetDirectoryName(System.Reflection.Assembly.GetExecutingAssembly().Location), "Velos-Setup.exe"), "isolated verification license", null, null, CancellationToken.None);
                        var version = System.Diagnostics.FileVersionInfo.GetVersionInfo(install.ApplicationPath).FileVersion;
                        if (version != BuildInfo.FileVersion || Shortcut.Target(link) != install.ApplicationPath) throw new IOException("实际程序或入口校验失败");
                        install.Uninstall();
                        using (var registered = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(key))
                            Check(!Directory.Exists(directory) && !File.Exists(link) && registered == null,
                                "公开 Release " + architecture + " 真实 EXE 下载、哈希、架构、版本、隔离安装及卸载通过");
                    }
                    finally { Microsoft.Win32.Registry.CurrentUser.DeleteSubKey(key, false); }
                }
            }
        }
        private static string Json(byte[] bytes)
        {
            var x64 = Asset(bytes); var x86 = Asset(bytes); x86.name = x86.name.Replace("x64", "x86"); x86.url = x86.url.Replace("x64", "x86");
            return new JavaScriptSerializer().Serialize(new ReleaseManifest { schema = 2, version = BuildInfo.Version, tag = BuildInfo.Tag, releaseUrl = BuildInfo.ReleaseUrl, minimumWindowsBuild = 19041, assets = new Dictionary<string, ReleaseAsset> { { "x64", x64 }, { "x86", x86 } } });
        }
        private static async Task Run()
        {
            Check(DownloadClient.Architecture(9) == "x64" && DownloadClient.Architecture(0) == "x86", "按系统架构识别，32 位下载器在 64 位系统仍选 x64");
            try { DownloadClient.Architecture(12); throw new Exception("未拒绝 ARM"); } catch (NotSupportedException) { Check(true, "不误下载 ARM 架构"); }
            var bytes = Encoding.UTF8.GetBytes("synthetic release data"); var json = Json(bytes);
            Check(ReleaseManifest.Parse(json).Asset("x86").name.EndsWith("win-x86.exe"), "发布清单解析与架构选择");
            foreach (var broken in new[] { json.Replace("SkuraSshly/Velos", "other/repository"), json.Replace(BuildInfo.Version, "0.0.0"), json.Replace(Asset(bytes).sha256, "not-a-hash") })
            {
                try { ReleaseManifest.Parse(broken); throw new Exception("未拒绝清单"); } catch (InvalidDataException) { Check(true, "拒绝仓库、版本或校验值不匹配"); }
            }
            using (var client = new DownloadClient(new Handler(delegate { return Task.FromResult(Bytes(Encoding.UTF8.GetBytes(json))); })))
                Check((await client.LoadAsync(CancellationToken.None)).version == BuildInfo.Version, "通过网络接口读取受限清单");
            var destination = Path.Combine(root, "success.exe"); if (File.Exists(destination)) throw new IOException("测试目录必须为空");
            using (var client = new DownloadClient(new Handler(delegate { return Task.FromResult(Bytes(bytes)); })))
                await client.SaveAsync(Asset(bytes), destination, false, null, CancellationToken.None);
            Check(Convert.ToBase64String(File.ReadAllBytes(destination)) == Convert.ToBase64String(bytes), "流式下载及 SHA-256 通过后才提交文件");
            var original = Path.Combine(root, "existing.exe"); File.WriteAllText(original, "original");
            using (var client = new DownloadClient(new Handler(delegate { return Task.FromResult(Bytes(Encoding.UTF8.GetBytes("corrupted release data"))); })))
            {
                try { await client.SaveAsync(Asset(bytes), original, true, null, CancellationToken.None); throw new Exception("未拒绝损坏文件"); }
                catch (InvalidDataException) { Check(File.ReadAllText(original) == "original", "校验失败不覆盖已有文件"); }
            }
            var invalidHash = Asset(bytes); invalidHash.sha256 = new string('0', 64);
            using (var client = new DownloadClient(new Handler(delegate { return Task.FromResult(Bytes(bytes)); })))
            {
                try { await client.SaveAsync(invalidHash, original, true, null, CancellationToken.None); throw new Exception("未验证哈希"); }
                catch (InvalidDataException) { Check(File.ReadAllText(original) == "original", "大小相同但内容校验错误仍拒绝"); }
            }
            using (var client = new DownloadClient(new Handler(delegate { return Task.FromResult(Bytes(bytes)); })))
                await client.SaveAsync(Asset(bytes), original, true, null, CancellationToken.None);
            Check(File.ReadAllText(original) == Encoding.UTF8.GetString(bytes), "用户确认覆盖后原子替换");
            var race = Path.Combine(root, "race.exe");
            using (var client = new DownloadClient(new Handler(delegate { File.WriteAllText(race, "another file"); return Task.FromResult(Bytes(bytes)); })))
            {
                try { await client.SaveAsync(Asset(bytes), race, false, null, CancellationToken.None); throw new Exception("误覆盖并发文件"); }
                catch (IOException) { Check(File.ReadAllText(race) == "another file", "下载期间出现同名文件也不会静默覆盖"); }
            }
            using (var cts = new CancellationTokenSource())
            using (var client = new DownloadClient(new Handler(delegate { return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StreamContent(new SlowStream()) }); })))
            {
                cts.CancelAfter(50); var slow = Asset(new byte[200]);
                try { await client.SaveAsync(slow, Path.Combine(root, "cancel.exe"), false, null, cts.Token); throw new Exception("未取消"); }
                catch (OperationCanceledException) { Check(!File.Exists(Path.Combine(root, "cancel.exe")), "下载取消不留下半成品"); }
            }
            using (var client = new DownloadClient(new Handler(delegate { var response = new HttpResponseMessage(HttpStatusCode.Redirect); response.Headers.Location = new Uri("http://example.invalid/file"); return Task.FromResult(response); })))
            {
                try { await client.SaveAsync(Asset(bytes), Path.Combine(root, "redirect.exe"), false, null, CancellationToken.None); throw new Exception("允许不安全重定向"); }
                catch (InvalidDataException) { Check(true, "拒绝 HTTPS 降级重定向"); }
            }
            await InstallationChecks();
            Check(Directory.GetFiles(root, "*.tmp").Length == 0, "完成、失败、取消后均清理自己的临时文件");
        }
        private sealed class Handler : HttpMessageHandler
        {
            private readonly Func<Task<HttpResponseMessage>> response;
            internal Handler(Func<Task<HttpResponseMessage>> response) { this.response = response; }
            protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token) { return response(); }
        }
        private sealed class SlowStream : Stream
        {
            public override bool CanRead { get { return true; } } public override bool CanSeek { get { return false; } } public override bool CanWrite { get { return false; } }
            public override long Length { get { throw new NotSupportedException(); } } public override long Position { get { return 0; } set { throw new NotSupportedException(); } }
            public override async Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken token) { await Task.Delay(15, token); buffer[offset] = 0; return 1; }
            public override int Read(byte[] buffer, int offset, int count) { throw new NotSupportedException(); }
            public override void Flush() { } public override long Seek(long offset, SeekOrigin origin) { throw new NotSupportedException(); }
            public override void SetLength(long value) { throw new NotSupportedException(); } public override void Write(byte[] buffer, int offset, int count) { throw new NotSupportedException(); }
        }
    }
}
